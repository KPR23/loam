import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { appleClientSecretExpiry, appleClientSecretNeedsRenewal } from "../_shared/apple_client_secret.ts";

function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left), b = encoder.encode(right);
  let mismatch = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) mismatch |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return mismatch === 0;
}

Deno.serve(async (request) => {
  if (request.method !== "GET") return new Response("Method not allowed", { status: 405, headers: { Allow: "GET" } });
  const monitorKey = Deno.env.get("DELETION_MONITOR_KEY");
  if (!monitorKey) return Response.json({ error: "monitor_not_configured" }, { status: 503 });
  if (!constantTimeEqual(request.headers.get("X-Deletion-Monitor-Key") ?? "", monitorKey)) {
    return new Response("Unauthorized", { status: 401 });
  }
  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return Response.json({ error: "monitor_not_configured" }, { status: 503 });
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data, error } = await admin.rpc("account_deletion_health");
  if (error || !data?.[0]) return Response.json({ error: "health_query_failed" }, { status: 503 });
  const health = data[0] as { last_heartbeat: string | null; last_notifier_heartbeat: string | null; oldest_pending: string | null; terminal_failures: number; pending_count: number; email_failures: number; retry_count: number; stage_counts: Record<string, number> };
  const now = Date.now();
  const alerts: string[] = [];
  if (!health.last_heartbeat || now - Date.parse(health.last_heartbeat) > 5 * 60_000) alerts.push("worker_heartbeat_missing");
  if (!health.last_notifier_heartbeat || now - Date.parse(health.last_notifier_heartbeat) > 5 * 60_000) alerts.push("notifier_heartbeat_missing");
  if (Number(health.terminal_failures) > 0) alerts.push("terminal_deletion_failure");
  const emailEnabled = Deno.env.get("DELETION_EMAIL_ENABLED") === "true";
  if (emailEnabled && Number(health.email_failures) > 0) alerts.push("terminal_email_delivery_failure");
  if (health.oldest_pending && now - Date.parse(health.oldest_pending) > 15 * 60_000) alerts.push("request_pending_over_15m");
  const appleClientSecret = Deno.env.get("APPLE_CLIENT_SECRET");
  if (appleClientSecretNeedsRenewal(appleClientSecret)) alerts.push("apple_client_secret_expiring");
  const body = { ok: alerts.length === 0, alerts, email_enabled: emailEnabled, last_heartbeat: health.last_heartbeat, last_notifier_heartbeat: health.last_notifier_heartbeat, oldest_pending: health.oldest_pending, terminal_failures: Number(health.terminal_failures), email_failures: Number(health.email_failures), retry_count: Number(health.retry_count), stage_counts: health.stage_counts ?? {}, pending_count: Number(health.pending_count), apple_client_secret_expires_at: appleClientSecretExpiry(appleClientSecret)?.toISOString() ?? null };
  return Response.json(body, { status: alerts.length ? 503 : 200 });
});
