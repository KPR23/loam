-- Occurrences were stepped from the previous one, so month-end rules drifted
-- (Jan 31 -> Feb 28 -> Mar 28). Each occurrence is now start_date plus a
-- whole number of intervals (Jan 31 -> Feb 28 -> Mar 31), matching the app.
create function private.recurring_occurrence(p_start date,p_unit text,p_count integer,p_index integer) returns date
language sql immutable set search_path='' as $$
  select (p_start+case p_unit when 'day' then make_interval(days=>p_index*p_count) when 'week' then make_interval(weeks=>p_index*p_count)
    when 'month' then make_interval(months=>p_index*p_count) else make_interval(years=>p_index*p_count) end)::date
$$;

create or replace function private.materialize_recurring_rule(p_rule_id uuid,p_through date) returns integer
language plpgsql set search_path='' as $$
declare r public.recurring_rule; d date; k integer; steps integer:=0; created integer:=0; elapsed interval;
begin
  select * into r from public.recurring_rule where id=p_rule_id for update;
  if not found or not r.is_active or r.next_occurrence>p_through then return 0; end if;
  -- Estimate the schedule index of next_occurrence, then step to the first
  -- scheduled date on or after it. A drifted next_occurrence snaps back.
  elapsed:=age(r.next_occurrence,r.start_date);
  k:=greatest(0,(case r.interval_unit when 'day' then r.next_occurrence-r.start_date when 'week' then (r.next_occurrence-r.start_date)/7
    when 'month' then (extract(year from elapsed)*12+extract(month from elapsed))::integer else extract(year from elapsed)::integer end)/r.interval_count-1);
  d:=private.recurring_occurrence(r.start_date,r.interval_unit,r.interval_count,k);
  while d<r.next_occurrence loop k:=k+1; d:=private.recurring_occurrence(r.start_date,r.interval_unit,r.interval_count,k); end loop;
  while d<=p_through and (r.end_date is null or d<=r.end_date) and steps<400 loop
    if not d=any(r.skipped_dates) and not exists(select 1 from public.expense where recurring_id=r.id and spent_at=d) then
      perform private.save_expense_as(r.owner_user_id,jsonb_build_object('id',gen_random_uuid(),'recurring_id',r.id,'spent_at',d,
        'amount_minor',r.amount_minor,'currency',r.currency,'category',r.category,'title',r.title,'note',r.note,'location',r.location,
        'paid_by',r.paid_by,'shares',r.shares),null);
      created:=created+1;
    end if;
    k:=k+1; d:=private.recurring_occurrence(r.start_date,r.interval_unit,r.interval_count,k); steps:=steps+1;
  end loop;
  update public.recurring_rule set next_occurrence=d,version=version+1 where id=r.id;
  return created;
end $$;

-- Functions get EXECUTE for PUBLIC regardless of per-schema defaults.
revoke all on function private.recurring_occurrence(date,text,integer,integer) from public,anon,authenticated;
