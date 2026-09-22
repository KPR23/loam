import { createClient } from "npm:@supabase/supabase-js@2.116.0";

// The caller's JWT is verified by the Functions gateway and again through
// Auth. No user ID or privileged key is accepted from the request body.
Deno.serve(async (request) => {
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

  try {
    // Deleting Storage files first is necessary before removing Auth access.
    // Older avatar uploads might remain even if the profile points at only one.
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

    // One database transaction redacts shared-history names and removes
    // private records. The retained user UUID keeps shared foreign keys valid.
    const { error: redactError } = await admin.rpc("redact_account_data", {
      p_user_id: user.id,
    });
    if (redactError) throw redactError;

    // Supabase Auth soft deletion preserves the user row for foreign keys,
    // removes sign-in identities, and revokes sessions.
    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id, true);
    if (deleteError) throw deleteError;

    return Response.json({ deleted: true });
  } catch (error) {
    console.error("Account deletion failed", error);
    return Response.json(
      { error: "Could not delete the account. Please try again." },
      { status: 500 },
    );
  }
});
