import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { accountIdsInWebhook, fetchProState, matchesSecret } from "../_shared/revenuecat.ts";

// RevenueCat sends every purchase, renewal, cancellation, expiry, refund and
// transfer here. The event only says which customers changed: their current
// entitlement is re-read from RevenueCat, so retries and out-of-order events
// always store the latest state. A non-2xx answer makes RevenueCat retry.
Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed" }, { status: 405 });

  const secret = Deno.env.get("REVENUECAT_WEBHOOK_AUTH") ?? "";
  if (!matchesSecret(request.headers.get("Authorization") ?? "", secret)) {
    return Response.json({ error: "Not authorized" }, { status: 401 });
  }
  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const apiKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");
  if (!url || !serviceKey || !apiKey) {
    console.error("RevenueCat webhook is missing server configuration");
    return Response.json({ error: "Unavailable" }, { status: 503 });
  }

  const accountIds = accountIdsInWebhook(await request.json().catch(() => null));
  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  try {
    for (const accountId of accountIds) {
      const state = await fetchProState(accountId, apiKey);
      const { error } = await admin.rpc("record_pro_entitlement", {
        p_account_id: accountId, p_active: state.active, p_expires_at: state.expiresAt,
      });
      if (error) throw new Error("record_pro_entitlement_failed");
    }
  } catch (error) {
    console.error(JSON.stringify({ event: "revenuecat_webhook_failed", code: error instanceof Error ? error.message : "unknown" }));
    return Response.json({ error: "Retry later" }, { status: 503 });
  }
  return Response.json({ synced: accountIds.length });
});
