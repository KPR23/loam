import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { createRemoteJWKSet, jwtVerify } from "npm:jose@5.10.0";

const deletionHash = async (value: string) => [...new Uint8Array(
  await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
const appleKeys = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

async function verifiedAppleSubject(token: string, clientId: string): Promise<string> {
  const { payload } = await jwtVerify(token, appleKeys, {
    issuer: "https://appleid.apple.com",
    audience: clientId,
  });
  if (typeof payload.sub !== "string" || !payload.sub) throw new Error("Apple token has no subject");
  return payload.sub;
}

async function encryptCredential(value: string): Promise<string> {
  const encodedKey = Deno.env.get("DELETION_CREDENTIAL_ENCRYPTION_KEY");
  if (!encodedKey) throw new Error("Deletion credential encryption is not configured");
  const rawKey = Uint8Array.from(atob(encodedKey), (char) => char.charCodeAt(0));
  if (rawKey.byteLength !== 32) throw new Error("Deletion credential encryption key is invalid");
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, new TextEncoder().encode(value)));
  return `${btoa(String.fromCharCode(...iv))}.${btoa(String.fromCharCode(...encrypted))}`;
}

// POST session tokens are verified against Auth here (the function also serves
// receipt-authorized GET status after the client has signed out). No user ID
// or privileged key is accepted from the request body.
Deno.serve(async (request) => {
  if (request.method === "GET") {
    const operationId = new URL(request.url).searchParams.get("operationId") ?? "";
    const receipt = request.headers.get("X-Deletion-Receipt") ?? "";
    if (!operationId || receipt.length < 32) {
      return Response.json({ error: "Invalid receipt" }, { status: 400 });
    }
    const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !serviceKey) return Response.json({ error: "Status service unavailable" }, { status: 503 });
    const status = await createClient(url, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    }).rpc("deletion_status", { p_operation_id: operationId, p_receipt_secret_hash: await deletionHash(receipt) });
    if (status.error) {
      console.error("Account deletion status query failed");
      return Response.json({ error: "Status service unavailable" }, { status: 503 });
    }
    return !status.data?.[0]
      ? Response.json({ error: "Not found" }, { status: 404 })
      : Response.json(status.data[0]);
  }
  if (request.method !== "POST") {
    return Response.json({ error: "Method not allowed" }, { status: 405 });
  }

  const authorization = request.headers.get("Authorization") ?? "";
  const token = authorization.startsWith("Bearer ")
    ? authorization.slice("Bearer ".length)
    : "";
  if (!token) {
    return Response.json({ error: "Not authenticated" }, { status: 401 });
  }

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) {
    console.error("Account deletion is missing server configuration");
    return Response.json({ error: "Account deletion is unavailable" }, { status: 503 });
  }

  const admin = createClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: { user }, error: authError } = await admin.auth.getUser(token);
  if (authError || !user) {
    return Response.json({ error: "Not authenticated" }, { status: 401 });
  }

  const payload = await request.clone().json().catch(() => ({})) as {
    operationId?: string; receiptSecret?: string; authorizationCode?: string; identityToken?: string;
  };
  if (!payload.operationId || !payload.receiptSecret || payload.receiptSecret.length < 32 || !payload.authorizationCode || !payload.identityToken) {
    return Response.json({ error: "A fresh Apple confirmation is required" }, { status: 400 });
  }

  try {
    const clientId = Deno.env.get("APPLE_CLIENT_ID");
    const appleSubject = user.identities?.find((identity) => identity.provider === "apple")?.id;
    if (!clientId || !appleSubject) return Response.json({ error: "This account is not linked to Apple" }, { status: 400 });
    const clientSecret = Deno.env.get("APPLE_CLIENT_SECRET");
    if (!clientSecret) return Response.json({ error: "Account deletion is unavailable" }, { status: 503 });
    const exchanged = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, code: payload.authorizationCode, grant_type: "authorization_code" }),
    });
    const appleTokens = await exchanged.json();
    if (!exchanged.ok || !appleTokens.refresh_token || !appleTokens.id_token) return Response.json({ error: "Apple confirmation could not be verified" }, { status: 400 });
    const exchangedSubject = await verifiedAppleSubject(appleTokens.id_token, clientId);
    // The returned, signature-verified ID token binds the exchanged one-time
    // code to the currently authenticated Supabase Apple identity. The client
    // supplied token is retained only as a second fresh-authorization check.
    const submittedSubject = await verifiedAppleSubject(payload.identityToken, clientId);
    if (exchangedSubject !== appleSubject || submittedSubject !== appleSubject || submittedSubject !== exchangedSubject) {
      return Response.json({ error: "Apple confirmation does not match this account" }, { status: 400 });
    }
    const { data, error } = await admin.rpc("accept_account_deletion", {
      p_operation_id: payload.operationId,
      p_account_id: user.id,
      p_receipt_secret_hash: await deletionHash(payload.receiptSecret),
      p_apple_subject: exchangedSubject,
      p_encrypted_credential: await encryptCredential(appleTokens.refresh_token),
      p_encrypted_notification_address: Deno.env.get("DELETION_EMAIL_ENABLED") === "true" && user.email && user.email_confirmed_at
        ? await encryptCredential(user.email)
        : "",
    });
    if (error) throw error;
    return Response.json({ operationId: data?.[0]?.operation_id ?? payload.operationId, status: data?.[0]?.complete ? "complete" : "processing" }, { status: data?.[0]?.complete ? 200 : 202 });
  } catch {
    console.error(JSON.stringify({ event: "account_deletion_acceptance_failed", code: "acceptance_unconfirmed" }));
    return Response.json({ error: "Could not confirm account deletion. Check the saved deletion status before retrying." }, { status: 500 });
  }
});
