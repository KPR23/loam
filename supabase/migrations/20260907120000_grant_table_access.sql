-- PostgREST needs table-level GRANTs; RLS then filters rows.
-- Without SELECT/INSERT/UPDATE/DELETE, clients get "permission denied"
-- and nested embeds like expense_share disappear from the schema cache.

grant usage on schema public to anon, authenticated, service_role;

grant select, insert, update, delete on all tables in schema public
  to anon, authenticated, service_role;

grant usage, select on all sequences in schema public
  to anon, authenticated, service_role;

alter default privileges in schema public
  grant select, insert, update, delete on tables
  to anon, authenticated, service_role;

alter default privileges in schema public
  grant usage, select on sequences
  to anon, authenticated, service_role;

grant select on public.v_personal_month_spend to authenticated;
grant select on public.v_household_balances to authenticated;

notify pgrst, 'reload schema';
