-- Existing deployments may already have applied the connection-code migration.
-- Keep its rate-limit helper private there too.
revoke all on function public.assert_connection_code_rate(text, integer, interval)
  from public, anon, authenticated;

notify pgrst, 'reload schema';
