import { createClient } from "npm:@supabase/supabase-js@2.116.0";

function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left), b = encoder.encode(right);
  let mismatch = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) mismatch |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return mismatch === 0;
}

// No email provider is configured yet, so the notifier only records its heartbeat
// for the monitor. Deletion requests retain no address while email stays disabled.
Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
  const expectedKey = Deno.env.get("DELETION_NOTIFIER_KEY");
  if (!expectedKey) return Response.json({ error: "notifier_not_configured" }, { status: 503 });
  if (!constantTimeEqual(request.headers.get("X-Deletion-Notifier-Key") ?? "", expectedKey)) return new Response("Unauthorized", { status: 401 });
  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return Response.json({ error: "notifier_not_configured" }, { status: 503 });
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { error: heartbeatError } = await admin.rpc("record_account_deletion_notifier_heartbeat", {
    p_processed: 0, p_retrying: 0, p_failed: 0,
  });
  if (heartbeatError) return Response.json({ error: "notifier_heartbeat_failed" }, { status: 500 });
  return Response.json({ email_enabled: false, processed: 0, retrying: 0, failed: 0 });
});
