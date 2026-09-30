import { createClient } from "npm:@supabase/supabase-js@2.116.0";
import { fetchProState, isAccountId } from "../_shared/revenuecat.ts";

// Called by the app right after a purchase or restore, so the backend knows
// about Pro before RevenueCat's webhook arrives. It only ever syncs the caller,
// and reads the entitlement from RevenueCat rather than trusting the app.
Deno.serve(async (request) => {
  if (request.method !== "POST") return Response.json({ error: "Method not allowed" }, { status: 405 });

  const authorization = request.headers.get("Authorization") ?? "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice("Bearer ".length) : "";
  if (!token) return Response.json({ error: "Not authenticated" }, { status: 401 });

  const url = Deno.env.get("SUPABASE_URL"), serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const apiKey = Deno.env.get("REVENUECAT_SECRET_API_KEY");
  if (!url || !serviceKey || !apiKey) {
    console.error("Pro entitlement sync is missing server configuration");
    return Response.json({ error: "Unavailable" }, { status: 503 });
  }

  const admin = createClient(url, serviceKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: { user }, error: authError } = await admin.auth.getUser(token);
  if (authError || !user || !isAccountId(user.id)) return Response.json({ error: "Not authenticated" }, { status: 401 });

  try {
    const state = await fetchProState(user.id, apiKey);
    const { error } = await admin.rpc("record_pro_entitlement", {
      p_account_id: user.id, p_active: state.active, p_expires_at: state.expiresAt,
    });
    if (error) throw new Error("record_pro_entitlement_failed");
    return Response.json({ active: state.active });
  } catch (error) {
    console.error(JSON.stringify({ event: "pro_entitlement_sync_failed", code: error instanceof Error ? error.message : "unknown" }));
    return Response.json({ error: "Unavailable" }, { status: 503 });
  }
});
