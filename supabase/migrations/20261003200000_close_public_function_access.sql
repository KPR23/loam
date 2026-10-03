-- New functions get EXECUTE for PUBLIC unless revoked, and this one came after the
-- per-schema revokes in secure_participant_model, so anon could call it. It rejects
-- callers without an active account, but it was never meant for anon.
revoke all on function public.materialize_recurring_rules(date) from public, anon;

-- Supabase installs this event-trigger function in new hosted projects. Triggers
-- don't need EXECUTE to fire, so no client role needs to be able to call it.
do $$ begin
  if to_regprocedure('public.rls_auto_enable()') is not null then
    revoke all on function public.rls_auto_enable() from public, anon, authenticated;
  end if;
end $$;

notify pgrst, 'reload schema';
