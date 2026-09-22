import { createClient } from "npm:@supabase/supabase-js@2.116.0";

async function decryptCredential(value: string): Promise<string> {
  const encodedKey = Deno.env.get("DELETION_CREDENTIAL_ENCRYPTION_KEY");
  if (!encodedKey) throw new Error("Deletion credential encryption is not configured");
  const [encodedIV, encodedCiphertext] = value.split(".");
  if (!encodedIV || !encodedCiphertext) throw new Error("Malformed encrypted deletion credential");
  const rawKey = Uint8Array.from(atob(encodedKey), (char) => char.charCodeAt(0));
  if (rawKey.byteLength !== 32) throw new Error("Deletion credential encryption key is invalid");
  const key = await crypto.subtle.importKey("raw", rawKey, "AES-GCM", false, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt({ name: "AES-GCM", iv: Uint8Array.from(atob(encodedIV), (char) => char.charCodeAt(0)) }, key, Uint8Array.from(atob(encodedCiphertext), (char) => char.charCodeAt(0)));
  return new TextDecoder().decode(plaintext);
}

async function advance(
  admin: ReturnType<typeof createClient>,
  job: { operation_id: string; stage: string; lease_token: string },
  nextStage: string,
  success: boolean,
  detail?: string,
): Promise<void> {
  const { data, error } = await admin.rpc("advance_account_deletion_job", {
    p_operation_id: job.operation_id, p_expected_stage: job.stage, p_lease_token: job.lease_token,
    p_next_stage: nextStage, p_success: success, p_detail: detail ?? null,
  });
  if (error || data !== true) {
    throw new Error(`Deletion job transition was not applied: ${error?.message ?? "lease expired or stage changed"}`);
  }
}

// Invoke this from a protected scheduler once a minute.  The database lease
// means concurrent invocations and worker crashes are safe.
Deno.serve(async (request) => {
  if (request.headers.get("X-Deletion-Worker-Key") !== Deno.env.get("DELETION_WORKER_KEY")) return new Response("Unauthorized", { status: 401 });
  const url = Deno.env.get("SUPABASE_URL")!, key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: jobs, error } = await admin.rpc("claim_account_deletion_job");
  if (error) return Response.json({ error: error.message }, { status: 500 });
  const job = jobs?.[0];
  if (!job) return Response.json({ processed: false });
  try {
    if (job.stage === "revoke_apple") {
      const result = await fetch("https://appleid.apple.com/auth/revoke", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ client_id: Deno.env.get("APPLE_CLIENT_ID")!, client_secret: Deno.env.get("APPLE_CLIENT_SECRET")!, token: await decryptCredential(job.credential), token_type_hint: "refresh_token" }) });
      if (!result.ok && result.status !== 400) throw new Error(`Apple revoke ${result.status}`);
      await advance(admin, job, "delete_auth", true);
    } else if (job.stage === "delete_auth") {
      const { error: deleteError } = await admin.auth.admin.deleteUser(job.account_id, true);
      if (deleteError && !/not found|already/i.test(deleteError.message)) throw deleteError;
      await advance(admin, job, "delete_avatars", true);
    } else if (job.stage === "delete_avatars") {
      const storage = admin.storage.from("avatars"), { data: files, error: listError } = await storage.list(job.account_id, { limit: 100 });
      if (listError) throw listError;
      if (files?.length) { const { error: removeError } = await storage.remove(files.map((file) => `${job.account_id}/${file.name}`)); if (removeError) throw removeError; }
      await advance(admin, job, files?.length ? "delete_avatars" : "complete", true);
    }
    return Response.json({ processed: true });
  } catch (error) {
    // If this compare-and-swap also fails, let the invocation fail. Reporting
    // success would conceal an RPC outage or an expired lease from the scheduler.
    await advance(admin, job, job.stage, false, String(error));
    return Response.json({ processed: true, retrying: true }, { status: 202 });
  }
});
