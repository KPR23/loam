import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { type ApnsConfig, sendApns } from "../_shared/apns.ts";
import { type PushEvent, pushContent } from "../_shared/push_content.ts";

function constantTimeEqual(left: string, right: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(left), b = encoder.encode(right);
  let mismatch = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) mismatch |= (a[i] ?? 0) ^ (b[i] ?? 0);
  return mismatch === 0;
}

interface PushContext extends PushEvent {
  user_id: string;
  badge: number;
  devices: { token: string; environment: "sandbox" | "production" }[];
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Called by the activity_event trigger through pg_net with the new event's ID.
Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response("Method not allowed", { status: 405, headers: { Allow: "POST" } });
  const expectedKey = Deno.env.get("PUSH_NOTIFICATION_KEY");
  if (!expectedKey) return Response.json({ error: "push_not_configured" }, { status: 503 });
  if (!constantTimeEqual(request.headers.get("X-Push-Key") ?? "", expectedKey)) return new Response("Unauthorized", { status: 401 });

  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const keyP8 = Deno.env.get("APNS_KEY_P8"), keyId = Deno.env.get("APNS_KEY_ID");
  const teamId = Deno.env.get("APNS_TEAM_ID"), topic = Deno.env.get("APNS_BUNDLE_ID");
  if (!url || !serviceKey || !keyP8 || !keyId || !teamId || !topic) return Response.json({ error: "push_not_configured" }, { status: 503 });
  const config: ApnsConfig = { keyP8: keyP8.replace(/\\n/g, "\n"), keyId, teamId, topic };

  const { event_id: eventId } = await request.json().catch(() => ({}));
  if (typeof eventId !== "string" || !UUID.test(eventId)) return Response.json({ error: "invalid_event" }, { status: 400 });

  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data, error } = await admin.rpc("push_event_context", { p_event_id: eventId });
  if (error) return Response.json({ error: "context_failed" }, { status: 500 });
  const context = (data as PushContext[] | null)?.[0];
  // Read, muted, own, or the account is gone: nothing to send.
  if (!context) return Response.json({ sent: 0, skipped: true });
  const content = pushContent(context, context.user_id);
  if (!content) return Response.json({ sent: 0, skipped: true });

  const payload = {
    aps: {
      alert: { title: content.title, body: content.body },
      sound: "default",
      badge: context.badge,
      "thread-id": context.expense_id ?? context.repayment_id ?? context.user_id,
    },
    event_id: eventId,
    user_id: context.user_id,
    kind: context.kind,
    ...(context.expense_id ? { expense_id: context.expense_id } : {}),
  };
  const outcomes = await Promise.all(
    context.devices.map((device) => sendApns(config, device, payload, { collapseId: eventId }).then((outcome) => ({ device, outcome }))),
  );
  const dead = outcomes.filter((o) => o.outcome === "dead").map((o) => o.device.token);
  if (dead.length) await admin.rpc("remove_push_devices", { p_tokens: dead });
  const retry = outcomes.some((o) => o.outcome === "retry");
  // 502 lets a caller that retries do so; the DB trigger is fire-and-forget.
  return Response.json(
    { sent: outcomes.filter((o) => o.outcome === "sent").length, removed: dead.length, retry },
    { status: retry ? 502 : 200 },
  );
});
