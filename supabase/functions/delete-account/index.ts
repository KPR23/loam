import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const deletionHash = async (value: string) => [...new Uint8Array(
  await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
)].map((byte) => byte.toString(16).padStart(2, "0")).join("");

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
    const status = await createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { autoRefreshToken: false, persistSession: false },
    }).rpc("deletion_status", { p_operation_id: operationId, p_receipt_secret_hash: await deletionHash(receipt) });
    return status.error || !status.data?.[0]
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
    const encodedClaims = payload.identityToken.split(".")[1];
    const claims = encodedClaims ? JSON.parse(atob(encodedClaims.replace(/-/g, "+").replace(/_/g, "/"))) : {};
    const clientId = Deno.env.get("APPLE_CLIENT_ID");
    const audience = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    const appleSubject = user.identities?.find((identity) => identity.provider === "apple")?.id;
    if (!clientId || !claims.sub || claims.sub !== appleSubject || claims.iss !== "https://appleid.apple.com" || !audience.includes(clientId) || !claims.exp || claims.exp * 1000 < Date.now()) {
      return Response.json({ error: "Apple confirmation does not match this account" }, { status: 400 });
    }
    const clientSecret = Deno.env.get("APPLE_CLIENT_SECRET");
    if (!clientSecret) return Response.json({ error: "Account deletion is unavailable" }, { status: 503 });
    const exchanged = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, code: payload.authorizationCode, grant_type: "authorization_code" }),
    });
    const appleTokens = await exchanged.json();
    if (!exchanged.ok || !appleTokens.refresh_token) return Response.json({ error: "Apple confirmation could not be verified" }, { status: 400 });
    const { data, error } = await admin.rpc("accept_account_deletion", {
      p_operation_id: payload.operationId,
      p_account_id: user.id,
      p_receipt_secret_hash: await deletionHash(payload.receiptSecret),
      p_apple_subject: claims.sub,
      // The worker revokes this short-lived credential before deleting Auth.
      p_encrypted_credential: appleTokens.refresh_token,
    });
    if (error) throw error;
    return Response.json({ operationId: data?.[0]?.operation_id ?? payload.operationId, status: data?.[0]?.complete ? "complete" : "processing" }, { status: data?.[0]?.complete ? 200 : 202 });
  } catch (error) {
    console.error("Account deletion acceptance failed", error);
    return Response.json({ error: "Could not accept account deletion. Your account has not changed." }, { status: 500 });
  }

  /* Legacy immediate-delete code intentionally unreachable: accepting deletion
     must first create the durable operation above. */
  try {
    // The database trigger redacts account data in the same transaction as this
    // Auth soft deletion. Do this before best-effort Storage cleanup: a failure
    // after this point can leave only inaccessible orphaned files, never a live
    // account with private data already destroyed.
    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id, true);
    if (deleteError) throw deleteError;

    // Older uploads might remain even if the profile points at only one avatar.
    // The bucket is private, and the account is already unable to authenticate,
    // so a cleanup failure is safe to retry operationally without reviving it.
    try {
      const avatars = admin.storage.from("avatars");
      for (let batch = 0; batch < 100; batch += 1) {
        const { data: files, error: listError } = await avatars.list(user.id, {
          limit: 100,
        });
        if (listError) throw listError;
        if (!files?.length) break;
        const paths = files.map((file) => `${user.id}/${file.name}`);
        const { error: removeError } = await avatars.remove(paths);
        if (removeError) throw removeError;
        if (batch === 99) throw new Error("Avatar cleanup exceeded batch limit");
      }
    } catch (cleanupError) {
      // Do not report a failed deletion after Auth and database deletion have
      // committed. The remaining files are private and can be removed later
      // with the service role.
      console.error("Avatar cleanup after account deletion failed", cleanupError);
      return Response.json({ deleted: true, avatarCleanupPending: true }, { status: 202 });
    }

    return Response.json({ deleted: true });
  } catch (error) {
    console.error("Account deletion failed", error);
    return Response.json(
      { error: "Could not delete the account. Please try again." },
      { status: 500 },
    );
  }
});
