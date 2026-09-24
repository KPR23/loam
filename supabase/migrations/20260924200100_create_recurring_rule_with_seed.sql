-- The app saved a recurring rule and then its first expense in two calls. The
-- hourly job could generate the seed date in between, so the app's insert hit
-- the unique rule/date index, and a failed seed left a rule that kept
-- generating expenses. Both are now saved in one transaction, with the rule
-- already advanced past the seed.
create function public.create_recurring_expense(p_rule jsonb,p_expense jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if (p_expense->>'spent_at')::date is distinct from (p_rule->>'start_date')::date
    or (p_rule->>'next_occurrence')::date<=(p_rule->>'start_date')::date then raise exception 'Invalid recurring expense'; end if;
  -- Without an expected version this only creates; an existing ID is rejected.
  perform public.save_recurring_rule(p_rule,null);
  return private.save_expense_as(auth.uid(),p_expense||jsonb_build_object('recurring_id',p_rule->>'id'),null);
end $$;

-- Functions get EXECUTE for PUBLIC regardless of per-schema defaults.
revoke all on function public.create_recurring_expense(jsonb,jsonb) from public,anon;
grant execute on function public.create_recurring_expense(jsonb,jsonb) to authenticated;

notify pgrst,'reload schema';
