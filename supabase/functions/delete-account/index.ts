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
