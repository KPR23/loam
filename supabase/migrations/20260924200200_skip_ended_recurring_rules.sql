-- A rule past its end date has nothing left to generate, but it was still
-- selected every hour and rewritten with a new version, which could reject
-- its owner's edits. Ended rules are no longer selected or rewritten.
create or replace function private.materialize_recurring_rule(p_rule_id uuid,p_through date) returns integer
language plpgsql set search_path='' as $$
declare r public.recurring_rule; d date; k integer; steps integer:=0; created integer:=0; elapsed interval;
begin
  select * into r from public.recurring_rule where id=p_rule_id for update;
  if not found or not r.is_active or r.next_occurrence>p_through or r.next_occurrence>r.end_date then return 0; end if;
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
  -- Only a moved schedule is an edit the owner's app has to reload.
  update public.recurring_rule set next_occurrence=d,version=version+(d<>r.next_occurrence)::integer where id=r.id;
  return created;
end $$;

create or replace function public.materialize_recurring_rules(p_through date default null) returns integer
language plpgsql security definer set search_path='' as $$
declare v_through date:=coalesce(p_through,current_date);
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  -- Clients send their local date; time zones spread it one day around UTC.
  if v_through not between current_date-1 and current_date+1 then raise exception 'Invalid date'; end if;
  return private.materialize_rules(array(select id from public.recurring_rule
    where owner_user_id=auth.uid() and is_active and next_occurrence<=v_through and (end_date is null or next_occurrence<=end_date)),v_through);
end $$;

create or replace function private.materialize_due_recurring_rules() returns integer
language sql set search_path='' as $$
  select private.materialize_rules(array(select id from public.recurring_rule
    where is_active and next_occurrence<=current_date and (end_date is null or next_occurrence<=end_date)),current_date)
$$;

notify pgrst,'reload schema';
