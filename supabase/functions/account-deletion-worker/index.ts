import { createClient } from "npm:@supabase/supabase-js@2.116.0";

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
      const result = await fetch("https://appleid.apple.com/auth/revoke", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" }, body: new URLSearchParams({ client_id: Deno.env.get("APPLE_CLIENT_ID")!, client_secret: Deno.env.get("APPLE_CLIENT_SECRET")!, token: job.credential, token_type_hint: "refresh_token" }) });
      if (!result.ok && result.status !== 400) throw new Error(`Apple revoke ${result.status}`);
      await admin.rpc("advance_account_deletion_job", { p_operation_id: job.operation_id, p_stage: "delete_auth", p_success: true });
    } else if (job.stage === "delete_auth") {
      const { error: deleteError } = await admin.auth.admin.deleteUser(job.account_id, true);
      if (deleteError && !/not found|already/i.test(deleteError.message)) throw deleteError;
      await admin.rpc("advance_account_deletion_job", { p_operation_id: job.operation_id, p_stage: "delete_avatars", p_success: true });
    } else if (job.stage === "delete_avatars") {
      const storage = admin.storage.from("avatars"), { data: files, error: listError } = await storage.list(job.account_id, { limit: 100 });
      if (listError) throw listError;
      if (files?.length) { const { error: removeError } = await storage.remove(files.map((file) => `${job.account_id}/${file.name}`)); if (removeError) throw removeError; }
      await admin.rpc("advance_account_deletion_job", { p_operation_id: job.operation_id, p_stage: files?.length ? "delete_avatars" : "complete", p_success: true });
    }
    return Response.json({ processed: true });
  } catch (error) {
    await admin.rpc("advance_account_deletion_job", { p_operation_id: job.operation_id, p_stage: job.stage, p_success: false, p_detail: String(error) });
    return Response.json({ processed: true, retrying: true }, { status: 202 });
  }
});
