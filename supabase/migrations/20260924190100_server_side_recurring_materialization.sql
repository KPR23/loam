-- Recurring occurrences are generated on the server from the rule itself,
-- so the rule is the only template and creation plus advancing
-- next_occurrence happen in one transaction. The owner's app triggers it on
-- refresh, and an hourly job covers owners who have not opened the app, so
-- other participants' balances do not wait for them.
create function private.materialize_recurring_rule(p_rule_id uuid,p_through date) returns integer
language plpgsql set search_path='' as $$
declare r public.recurring_rule; d date; step interval; steps integer:=0; created integer:=0;
begin
  select * into r from public.recurring_rule where id=p_rule_id for update;
  if not found or not r.is_active or r.next_occurrence>p_through then return 0; end if;
  step:=case r.interval_unit when 'day' then make_interval(days=>r.interval_count) when 'week' then make_interval(weeks=>r.interval_count)
    when 'month' then make_interval(months=>r.interval_count) else make_interval(years=>r.interval_count) end;
  d:=r.next_occurrence;
  -- Same stepping as the app: one interval after the previous occurrence.
  while d<=p_through and (r.end_date is null or d<=r.end_date) and steps<400 loop
    if not d=any(r.skipped_dates) and not exists(select 1 from public.expense where recurring_id=r.id and spent_at=d) then
      perform private.save_expense_as(r.owner_user_id,jsonb_build_object('id',gen_random_uuid(),'recurring_id',r.id,'spent_at',d,
        'amount_minor',r.amount_minor,'currency',r.currency,'category',r.category,'title',r.title,'note',r.note,'location',r.location,
        'paid_by',r.paid_by,'shares',r.shares),null);
      created:=created+1;
    end if;
    d:=(d+step)::date; steps:=steps+1;
  end loop;
  update public.recurring_rule set next_occurrence=d,version=version+1 where id=r.id;
  return created;
end $$;

-- One failing rule (for example a participant who can no longer be split
-- with) must not block the others or the caller's refresh. It stays due and
-- is retried; the warning lands in the database logs.
create function private.materialize_rules(p_rule_ids uuid[],p_through date) returns integer
language plpgsql set search_path='' as $$
declare v_id uuid; total integer:=0;
begin
  foreach v_id in array coalesce(p_rule_ids,'{}') loop
    begin total:=total+private.materialize_recurring_rule(v_id,p_through);
    exception when others then raise warning 'Recurring rule % was not materialized: %',v_id,sqlerrm; end;
  end loop;
  return total;
end $$;

create function public.materialize_recurring_rules(p_through date default null) returns integer
language plpgsql security definer set search_path='' as $$
declare v_through date:=coalesce(p_through,current_date);
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  -- Clients send their local date; time zones spread it one day around UTC.
  if v_through not between current_date-1 and current_date+1 then raise exception 'Invalid date'; end if;
  return private.materialize_rules(array(select id from public.recurring_rule
    where owner_user_id=auth.uid() and is_active and next_occurrence<=v_through),v_through);
end $$;
grant execute on function public.materialize_recurring_rules(date) to authenticated;

create function private.materialize_due_recurring_rules() returns integer
language sql set search_path='' as $$
  select private.materialize_rules(array(select id from public.recurring_rule where is_active and next_occurrence<=current_date),current_date)
$$;

-- Functions get EXECUTE for PUBLIC regardless of per-schema defaults.
revoke all on function private.materialize_recurring_rule(uuid,date),private.materialize_rules(uuid[],date),
  private.materialize_due_recurring_rules() from public,anon,authenticated;

do $$ begin
  if not exists(select 1 from cron.job where jobname='loam-recurring-materializer') then
    perform cron.schedule('loam-recurring-materializer','5 * * * *','select private.materialize_due_recurring_rules()');
  end if;
end $$;

notify pgrst,'reload schema';
