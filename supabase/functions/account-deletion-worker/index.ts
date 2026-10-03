import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { requireAppleRevocationSuccess } from "../_shared/apple_revoke.ts";
import { deletePostHogPerson } from "../_shared/posthog_delete.ts";

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

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
  const workerKey = Deno.env.get("DELETION_WORKER_KEY");
  const url = Deno.env.get("SUPABASE_URL"), key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!workerKey || !url || !key) return Response.json({ error: "worker_not_configured" }, { status: 503 });
  const suppliedKey = request.headers.get("X-Deletion-Worker-Key") ?? "";
  const expected = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(workerKey));
  const supplied = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(suppliedKey));
  const expectedBytes = new Uint8Array(expected), suppliedBytes = new Uint8Array(supplied);
  let difference = expectedBytes.length ^ suppliedBytes.length;
  for (let i = 0; i < expectedBytes.length; i++) difference |= expectedBytes[i] ^ suppliedBytes[i];
  if (difference !== 0) return new Response("Unauthorized", { status: 401 });
  const admin = createClient(url, key, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: jobs, error } = await admin.rpc("claim_account_deletion_job");
  if (error) {
    console.error(JSON.stringify({ event: "deletion_claim_failed", code: "claim_rpc_error" }));
    return Response.json({ error: "claim_failed" }, { status: 500 });
  }
  const startedAt = Date.now();
  let processed = 0, retrying = 0, failed = 0;
  for (const job of jobs ?? []) {
    if (Date.now() - startedAt > 45_000) break;
    try {
      if (job.stage === "revoke_apple") {
        const clientId = Deno.env.get("APPLE_CLIENT_ID"), clientSecret = Deno.env.get("APPLE_CLIENT_SECRET");
        if (!clientId || !clientSecret) throw new Error("apple_configuration_missing");
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 12_000);
        let result: Response;
        try {
          result = await fetch("https://appleid.apple.com/auth/revoke", {
            method: "POST", signal: controller.signal,
            headers: { "content-type": "application/x-www-form-urlencoded" },
            body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, token: await decryptCredential(job.credential), token_type_hint: "refresh_token" }),
          });
        } finally { clearTimeout(timeout); }
        await requireAppleRevocationSuccess(result);
        await advance(admin, job, "delete_avatars", true);
      } else if (job.stage === "delete_avatars") {
        const storage = admin.storage.from("avatars"), { data: files, error: listError } = await storage.list(job.account_id, { limit: 100 });
        if (listError) throw new Error("avatar_list_failed");
        if (files?.length) {
          const { error: removeError } = await storage.remove(files.map((file) => `${job.account_id}/${file.name}`));
          if (removeError) throw new Error("avatar_remove_failed");
        }
        await advance(admin, job, files?.length ? "delete_avatars" : "delete_analytics", true);
      } else if (job.stage === "delete_analytics") {
        const projectId = Deno.env.get("POSTHOG_PROJECT_ID"), apiKey = Deno.env.get("POSTHOG_PERSONAL_API_KEY");
        if (!projectId || !apiKey) throw new Error("posthog_configuration_missing");
        await deletePostHogPerson(job.account_id, { host: Deno.env.get("POSTHOG_API_HOST") ?? "https://eu.posthog.com", projectId, apiKey });
        await advance(admin, job, "delete_auth", true);
      } else if (job.stage === "delete_auth") {
        // Keep the Supabase soft-delete tombstone because shared expense rows
        // still reference this identity. Soft deletion disables future sessions;
        // active-account RLS also rejects already-issued JWTs.
        const { error: deleteError } = await admin.auth.admin.deleteUser(job.account_id, true);
        if (deleteError && !/not found|already/i.test(deleteError.message)) throw new Error("auth_delete_failed");
        await advance(admin, job, "complete", true);
      } else {
        throw new Error("unknown_deletion_stage");
      }
      processed++;
      console.info(JSON.stringify({ event: "deletion_stage_advanced", operation_id: job.operation_id, stage: job.stage }));
    } catch (error) {
      const code = error instanceof Error ? error.message : "worker_error";
      try {
        await advance(admin, job, job.stage, false, code);
        retrying++;
        console.error(JSON.stringify({ event: "deletion_stage_retry", operation_id: job.operation_id, stage: job.stage, code }));
      } catch {
        failed++;
        console.error(JSON.stringify({ event: "deletion_stage_transition_failed", operation_id: job.operation_id, stage: job.stage, code: "transition_failed" }));
      }
    }
  }
  const { error: purgeError } = await admin.rpc("purge_completed_account_deletions");
  if (purgeError) console.error(JSON.stringify({ event: "deletion_receipt_purge_failed", code: "purge_rpc_error" }));
  const { error: heartbeatError } = await admin.rpc("record_account_deletion_heartbeat", {
    p_processed: processed, p_retrying: retrying, p_failed: failed,
  });
  if (heartbeatError) {
    console.error(JSON.stringify({ event: "deletion_heartbeat_failed", code: "heartbeat_rpc_error" }));
    return Response.json({ error: "heartbeat_failed" }, { status: 500 });
  }
  return Response.json({ processed, retrying, failed });
});
