-- Participant-based sharing. All financial writes go through validated RPCs.
-- Existing expense history survives; old household-scoped trust is cleared
-- rather than silently expanding the scope of a user's consent.
drop view if exists public.v_personal_month_spend;

do $$ declare r record; begin
  for r in select schemaname,tablename,policyname from pg_policies
    where schemaname='public' and tablename in
      ('expense','expense_share','expense_share_trust','expense_edit_proposal','recurring_rule','household','household_member')
  loop execute format('drop policy %I on %I.%I',r.policyname,r.schemaname,r.tablename); end loop;
  for r in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('ensure_split_household','ensure_test_household','is_household_member','is_household_owner',
      'is_placeholder_partner','auth_is_placeholder_partner','update_expense_with_shares','create_expense_edit_proposal','respond_to_edit_proposal')
  loop execute format('drop function %s',r.signature); end loop;
end $$;


drop trigger if exists activity_expense_edited on public.expense;
drop trigger if exists activity_share_created on public.expense_share;
drop trigger if exists activity_share_responded on public.expense_share;
drop trigger if exists activity_share_removed on public.expense_share;
drop trigger if exists activity_proposal_created on public.expense_edit_proposal;
drop trigger if exists activity_proposal_status on public.expense_edit_proposal;
drop trigger if exists expense_share_set_status on public.expense_share;
drop function public.set_expense_share_status_on_insert();
drop function public.share_status_for_insert(uuid,uuid);
drop function public.log_expense_activity();
drop function public.log_share_activity();
drop function public.log_share_response_activity();
drop function public.log_removed_share_activity();
drop function public.log_proposal_activity();

alter table public.expense add column version bigint not null default 1 check(version>0);
alter table public.expense add constraint expense_currency_check check(currency in ('PLN','EUR','USD'));
alter table public.recurring_rule add column paid_by uuid references auth.users(id);
alter table public.recurring_rule add column shares jsonb;
alter table public.recurring_rule add column version bigint not null default 1 check(version>0);
update public.recurring_rule r set paid_by=coalesce(
  (select paid_by from public.expense where recurring_id=r.id order by spent_at desc,created_at desc limit 1),owner_user_id),
  shares=coalesce((select jsonb_agg(jsonb_build_object('user_id',s.user_id,'amount_minor',s.amount_minor))
    from public.expense_share s where s.expense_id=(select id from public.expense where recurring_id=r.id order by spent_at desc,created_at desc limit 1)),
    jsonb_build_array(jsonb_build_object('user_id',owner_user_id,'amount_minor',amount_minor)));
alter table public.recurring_rule alter column paid_by set not null;
alter table public.recurring_rule alter column shares set not null;
alter table public.recurring_rule add constraint recurring_currency_check check(currency in ('PLN','EUR','USD'));
alter table public.recurring_rule add constraint recurring_dates_check check(end_date is null or end_date>=start_date);
alter table public.recurring_rule add constraint recurring_next_date_check check(next_occurrence>=start_date);
alter table public.recurring_rule add constraint recurring_shares_array_check check(jsonb_typeof(shares)='array' and jsonb_array_length(shares) between 1 and 9);
alter table public.expense_edit_proposal add column base_version bigint;
alter table public.expense_edit_proposal add column currency text;
update public.expense_edit_proposal p set base_version=e.version,currency=e.currency,
  status=case when p.status='pending' then 'withdrawn'::public.expense_proposal_status else p.status end
  from public.expense e where e.id=p.expense_id;
alter table public.expense_edit_proposal alter column base_version set not null;
alter table public.expense_edit_proposal alter column currency set not null;
alter table public.expense_edit_proposal add constraint proposal_currency_check check(currency in ('PLN','EUR','USD'));
alter table public.expense_edit_proposal add constraint proposal_shares_array_check check(jsonb_typeof(shares)='array' and jsonb_array_length(shares) between 1 and 9);
delete from public.expense_share_trust;
alter table public.expense_share_trust drop column household_id;
alter table public.expense_share_trust add constraint trust_user_pair_unique unique(user_id,trusted_user_id);
alter table public.expense drop column household_id;
alter table public.recurring_rule drop column household_id;

create or replace function public.activity_name(p_user_id uuid) returns text
language sql stable security definer set search_path='' as $$
  select coalesce((select display_name from public.profile where id=p_user_id),'Someone')
$$;

-- Helpers are in the unexposed schema with no public execution grants.
create function private.validate_expense_payload(p_owner uuid,p_paid_by uuid,p_amount integer,p_currency text,p_shares jsonb)
returns void language plpgsql set search_path='' as $$
declare v_ids uuid[]; v_sum bigint;
begin
  if p_owner is null or p_paid_by is null or p_amount is null or p_amount<=0
     or p_currency is null or p_currency not in ('PLN','EUR','USD') then raise exception 'Invalid expense'; end if;
  if p_shares is null or jsonb_typeof(p_shares)<>'array' then raise exception 'Invalid shares'; end if;
  if jsonb_array_length(p_shares) not between 1 and 9 then raise exception 'Choose between 1 and 9 participants'; end if;
  if exists(select 1 from jsonb_array_elements(p_shares) s where jsonb_typeof(s)<>'object'
    or s->>'user_id' is null or s->>'amount_minor' is null
    or jsonb_typeof(s->'amount_minor')<>'number' or (s->>'amount_minor') !~ '^[0-9]+$') then raise exception 'Invalid shares'; end if;
  select array_agg((s->>'user_id')::uuid),sum((s->>'amount_minor')::bigint) into v_ids,v_sum from jsonb_array_elements(p_shares) s;
  if v_sum<>p_amount or cardinality(v_ids)<>(select count(distinct x) from unnest(v_ids) x)
     or not p_owner=any(v_ids) or not p_paid_by=any(v_ids) then raise exception 'Invalid payer, participants or total'; end if;
  if exists(select 1 from unnest(v_ids) u where not exists(select 1 from public.profile p where p.id=u and p.deleted_at is null))
    then raise exception 'Participant unavailable'; end if;
  if exists(select 1 from unnest(v_ids) u where u<>p_owner and not exists(
    select 1 from public.user_connection c where c.accepted_at is not null
      and ((c.user_a=p_owner and c.user_b=u) or (c.user_b=p_owner and c.user_a=u))))
    then raise exception 'Every participant must be connected to the creator'; end if;
end $$;

create function private.expense_shares(p_expense_id uuid) returns jsonb
language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'amount_minor',amount_minor) order by user_id),'[]'::jsonb)
  from public.expense_share where expense_id=p_expense_id
$$;

create function private.log_expense_event(p_kind text,p_expense public.expense,p_shares jsonb,p_actor uuid,p_audience uuid[] default null)
returns void language plpgsql set search_path='' as $$
begin
  if jsonb_array_length(p_shares)<2 then return; end if;
  insert into public.activity_event(audience_user_id,kind,actor_id,actor_name,recipient_id,recipient_name,recipient_names,
    expense_id,expense_title,category,affected_share_minor,expense_total_minor,currency)
  select (s->>'user_id')::uuid,p_kind,p_actor,public.activity_name(p_actor),
    case when p_actor<>p_expense.created_by then p_expense.created_by end,
    case when p_actor<>p_expense.created_by then public.activity_name(p_expense.created_by) end,
    array(select public.activity_name((x->>'user_id')::uuid) from jsonb_array_elements(p_shares) x where (x->>'user_id')::uuid<>p_actor),
    p_expense.id,coalesce(nullif(p_expense.title,''),initcap(p_expense.category::text)),p_expense.category,
    (s->>'amount_minor')::integer,p_expense.amount_minor,p_expense.currency
  from jsonb_array_elements(p_shares) s where p_audience is null or (s->>'user_id')::uuid=any(p_audience);
end $$;

create or replace function public.log_deleted_expense_activity() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  perform private.log_expense_event('deleted',old,private.expense_shares(old.id),coalesce(auth.uid(),old.created_by));
  return old;
end $$;

-- Deferred checks cover parent updates as well as child mutations.
create function private.assert_expense_integrity(p_id uuid) returns void
language plpgsql set search_path='' as $$
declare e public.expense; total bigint; n integer; creator_present boolean; payer_present boolean;
begin
  select * into e from public.expense where id=p_id;
  if not found then return; end if;
  select sum(amount_minor),count(*),bool_or(user_id=e.created_by),bool_or(user_id=e.paid_by)
    into total,n,creator_present,payer_present from public.expense_share where expense_id=p_id;
  if total is distinct from e.amount_minor::bigint or n not between 1 and 9 or not coalesce(creator_present,false) or not coalesce(payer_present,false)
    then raise exception 'Expense must have matching shares including creator and payer'; end if;
end $$;
create or replace function public.enforce_expense_share_sum() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if tg_table_name='expense' then
    perform private.assert_expense_integrity(new.id);
  else
    if tg_op<>'DELETE' then perform private.assert_expense_integrity(new.expense_id); end if;
    if tg_op<>'INSERT' then perform private.assert_expense_integrity(old.expense_id); end if;
  end if;
  return null;
end $$;
create constraint trigger expense_total_check after insert or update on public.expense
  deferrable initially deferred for each row execute function public.enforce_expense_share_sum();

create function public.save_expense(p_expense jsonb,p_expected_version bigint default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare e public.expense; old_e public.expense; old_shares jsonb; s jsonb; v_id uuid:=(p_expense->>'id')::uuid;
  v_uid uuid:=auth.uid(); v_status public.expense_share_status; v_trust boolean; v_recurring uuid:=(p_expense->>'recurring_id')::uuid;
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if v_id is null then raise exception 'Expense ID is required'; end if;
  -- Serialize creation retries for an ID, then lock the actual row for edits.
  perform pg_advisory_xact_lock(hashtextextended(v_id::text,5));
  select * into old_e from public.expense where id=v_id for update;
  if found then
    if old_e.created_by<>v_uid then raise exception 'Expense not found'; end if;
    if p_expected_version is null or p_expected_version<>old_e.version then raise exception 'Expense changed. Refresh and try again.'; end if;
  elsif p_expected_version is not null then raise exception 'Expense not found'; end if;
  perform private.validate_expense_payload(v_uid,(p_expense->>'paid_by')::uuid,(p_expense->>'amount_minor')::integer,p_expense->>'currency',p_expense->'shares');
  if v_recurring is not null and not exists(select 1 from public.recurring_rule where id=v_recurring and owner_user_id=v_uid)
    then raise exception 'Recurring rule not found'; end if;
  if p_expense->>'spent_at' is null then raise exception 'Date is required'; end if;
  old_shares:=private.expense_shares(v_id);
  insert into public.expense(id,amount_minor,currency,category,title,note,location,spent_at,paid_by,created_by,recurring_id)
  values(v_id,(p_expense->>'amount_minor')::integer,p_expense->>'currency',(p_expense->>'category')::public.expense_category,
    p_expense->>'title',p_expense->>'note',nullif(p_expense->'location','null'::jsonb),(p_expense->>'spent_at')::date,(p_expense->>'paid_by')::uuid,v_uid,v_recurring)
  on conflict(id) do update set amount_minor=excluded.amount_minor,currency=excluded.currency,category=excluded.category,title=excluded.title,
    note=excluded.note,location=excluded.location,spent_at=excluded.spent_at,paid_by=excluded.paid_by,recurring_id=excluded.recurring_id,
    version=public.expense.version+1,updated_at=now() returning * into e;
  delete from public.expense_share where expense_id=v_id;
  for s in select * from jsonb_array_elements(p_expense->'shares') loop
    v_trust:=(s->>'user_id')::uuid<>v_uid and exists(select 1 from public.expense_share_trust where user_id=(s->>'user_id')::uuid and trusted_user_id=v_uid);
    v_status:=case when (s->>'user_id')::uuid=v_uid or v_trust then 'accepted'::public.expense_share_status else 'pending'::public.expense_share_status end;
    insert into public.expense_share(expense_id,user_id,amount_minor,status,responded_at,accepted_via_trust)
      values(v_id,(s->>'user_id')::uuid,(s->>'amount_minor')::integer,v_status,case when v_status='accepted' then now() end,v_trust);
  end loop;
  perform private.assert_expense_integrity(v_id);
  update public.expense_edit_proposal set status='withdrawn',responded_at=now() where expense_id=v_id and status='pending';
  perform private.log_expense_event(case when old_e.id is null then 'shared' else 'edited' end,e,private.expense_shares(v_id),v_uid);
  if old_e.id is not null then
    perform private.log_expense_event('participant_removed',old_e,old_shares,v_uid,
      array(select (x->>'user_id')::uuid from jsonb_array_elements(old_shares) x where not exists(
        select 1 from public.expense_share where expense_id=v_id and user_id=(x->>'user_id')::uuid)));
  end if;
  return v_id;
end $$;

create or replace function public.respond_to_expense_share(p_expense_id uuid,p_action text) returns void
language plpgsql security definer set search_path='' as $$
declare e public.expense; v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if p_action is null or p_action not in ('accept','reject','accept_with_trust') then raise exception 'Invalid action'; end if;
  select * into e from public.expense where id=p_expense_id for update;
  if not found then raise exception 'Expense not found'; end if;
  update public.expense_share set status=case when p_action='reject' then 'rejected'::public.expense_share_status else 'accepted'::public.expense_share_status end,
    responded_at=now(),accepted_via_trust=false where expense_id=e.id and user_id=v_uid and status='pending';
  if not found then raise exception 'Pending share not found'; end if;
  if p_action='accept_with_trust' then
    if not public.are_connected(v_uid,e.created_by) then raise exception 'Connection required'; end if;
    insert into public.expense_share_trust(user_id,trusted_user_id) values(v_uid,e.created_by) on conflict(user_id,trusted_user_id) do nothing;
  end if;
  perform private.log_expense_event(case when p_action='reject' then 'rejected' else 'accepted' end,e,private.expense_shares(e.id),v_uid,array[v_uid,e.created_by]);
end $$;

create function public.create_expense_edit_proposal(p_expense_id uuid,p_expected_version bigint,p_proposal jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare e public.expense; v_id uuid; v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  select * into e from public.expense where id=p_expense_id for update;
  if not found or e.created_by=v_uid or not exists(select 1 from public.expense_share where expense_id=e.id and user_id=v_uid)
    then raise exception 'Expense not found'; end if;
  if p_expected_version is distinct from e.version then raise exception 'Expense changed. Refresh and try again.'; end if;
  perform private.validate_expense_payload(e.created_by,(p_proposal->>'paid_by')::uuid,(p_proposal->>'amount_minor')::integer,e.currency,p_proposal->'shares');
  update public.expense_edit_proposal set status='withdrawn',responded_at=now() where expense_id=e.id and proposed_by=v_uid and status='pending';
  insert into public.expense_edit_proposal(expense_id,proposed_by,base_version,currency,amount_minor,category,title,note,location,spent_at,paid_by,shares,message)
  values(e.id,v_uid,e.version,e.currency,(p_proposal->>'amount_minor')::integer,(p_proposal->>'category')::public.expense_category,
    p_proposal->>'title',p_proposal->>'note',nullif(p_proposal->'location','null'::jsonb),(p_proposal->>'spent_at')::date,
    (p_proposal->>'paid_by')::uuid,p_proposal->'shares',p_proposal->>'message') returning id into v_id;
  perform private.log_expense_event('proposal_created',e,private.expense_shares(e.id),v_uid,array[v_uid,e.created_by]);
  return v_id;
end $$;

create function public.respond_to_edit_proposal(p_proposal_id uuid,p_accept boolean) returns void
language plpgsql security definer set search_path='' as $$
declare p public.expense_edit_proposal; e public.expense; v_expense_id uuid;
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  -- Use the same advisory-lock then row-lock order as save_expense.
  select expense_id into v_expense_id from public.expense_edit_proposal where id=p_proposal_id;
  if v_expense_id is null then raise exception 'Proposal not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_expense_id::text,5));
  select e0.* into e from public.expense e0 join public.expense_edit_proposal p0 on p0.expense_id=e0.id where p0.id=p_proposal_id for update of e0;
  if not found or e.created_by<>auth.uid() then raise exception 'Proposal not found'; end if;
  select * into p from public.expense_edit_proposal where id=p_proposal_id for update;
  if p.status<>'pending' or p_accept is null then raise exception 'Proposal is no longer pending'; end if;
  if p_accept then
    if p.base_version<>e.version or p.currency<>e.currency then raise exception 'Expense changed. Request a new proposal.'; end if;
    if not exists(select 1 from public.expense_share where expense_id=e.id and user_id=p.proposed_by) then raise exception 'Proposer is no longer a participant'; end if;
    perform public.save_expense(to_jsonb(p)||jsonb_build_object('id',e.id,'recurring_id',e.recurring_id),e.version);
    select * into e from public.expense where id=e.id;
  end if;
  update public.expense_edit_proposal set status=case when p_accept then 'accepted'::public.expense_proposal_status else 'rejected'::public.expense_proposal_status end,
    responded_at=now() where id=p.id;
  perform private.log_expense_event(case when p_accept then 'proposal_accepted' else 'proposal_rejected' end,e,private.expense_shares(e.id),auth.uid(),array[p.proposed_by,e.created_by]);
end $$;

create function public.save_recurring_rule(p_rule jsonb,p_expected_version bigint default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.recurring_rule; v_id uuid:=(p_rule->>'id')::uuid; v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if v_id is null then raise exception 'Rule ID is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_id::text,6));
  select * into r from public.recurring_rule where id=v_id for update;
  if found then
    if r.owner_user_id<>v_uid then raise exception 'Rule not found'; end if;
    if p_expected_version is distinct from r.version then raise exception 'Recurring rule changed. Refresh and try again.'; end if;
  elsif p_expected_version is not null then raise exception 'Rule not found'; end if;
  perform private.validate_expense_payload(v_uid,(p_rule->>'paid_by')::uuid,(p_rule->>'amount_minor')::integer,p_rule->>'currency',p_rule->'shares');
  insert into public.recurring_rule(id,owner_user_id,paid_by,shares,amount_minor,currency,category,title,note,location,interval_unit,interval_count,start_date,end_date,next_occurrence,skipped_dates,is_active)
  values(v_id,v_uid,(p_rule->>'paid_by')::uuid,p_rule->'shares',(p_rule->>'amount_minor')::integer,p_rule->>'currency',(p_rule->>'category')::public.expense_category,
    p_rule->>'title',p_rule->>'note',nullif(p_rule->'location','null'::jsonb),p_rule->>'interval_unit',(p_rule->>'interval_count')::integer,
    (p_rule->>'start_date')::date,(p_rule->>'end_date')::date,(p_rule->>'next_occurrence')::date,
    array(select value::date from jsonb_array_elements_text(coalesce(p_rule->'skipped_dates','[]'::jsonb))),coalesce((p_rule->>'is_active')::boolean,true))
  on conflict(id) do update set paid_by=excluded.paid_by,shares=excluded.shares,amount_minor=excluded.amount_minor,currency=excluded.currency,category=excluded.category,
    title=excluded.title,note=excluded.note,location=excluded.location,interval_unit=excluded.interval_unit,interval_count=excluded.interval_count,
    start_date=excluded.start_date,end_date=excluded.end_date,next_occurrence=excluded.next_occurrence,skipped_dates=excluded.skipped_dates,is_active=excluded.is_active,version=public.recurring_rule.version+1;
  return v_id;
end $$;

create function public.activity_page(p_before_id uuid default null) returns setof public.activity_event
language sql stable security invoker set search_path='' as $$
  select a.* from public.activity_event a where p_before_id is null or (a.occurred_at,a.id)<
    (select b.occurred_at,b.id from public.activity_event b where b.id=p_before_id)
  order by a.occurred_at desc,a.id desc limit 51
$$;

-- SELECT is exposed; mutation RPCs own the financial state machine.
create policy expense_read on public.expense for select to authenticated using ((select public.current_account_is_active()) and
  (created_by=(select auth.uid()) or exists(select 1 from public.expense_share s where s.expense_id=expense.id and s.user_id=(select auth.uid()))));
create policy expense_delete on public.expense for delete to authenticated using ((select public.current_account_is_active()) and created_by=(select auth.uid()));
create policy share_read on public.expense_share for select to authenticated using (private.can_read_expense_shares(expense_id));
create policy recurring_read on public.recurring_rule for select to authenticated using ((select public.current_account_is_active()) and owner_user_id=(select auth.uid()));
create policy recurring_delete on public.recurring_rule for delete to authenticated using ((select public.current_account_is_active()) and owner_user_id=(select auth.uid()));
create policy proposal_read on public.expense_edit_proposal for select to authenticated using ((select public.current_account_is_active()) and
  (proposed_by=(select auth.uid()) or exists(select 1 from public.expense e where e.id=expense_id and e.created_by=(select auth.uid()))));
create policy trust_read on public.expense_share_trust for select to authenticated using ((select public.current_account_is_active()) and user_id=(select auth.uid()));
create policy trust_insert on public.expense_share_trust for insert to authenticated with check ((select public.current_account_is_active()) and user_id=(select auth.uid()) and public.are_connected(user_id,trusted_user_id));
create policy trust_delete on public.expense_share_trust for delete to authenticated using ((select public.current_account_is_active()) and user_id=(select auth.uid()));

create or replace function public.update_display_name(p_display_name text) returns void language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if nullif(btrim(p_display_name),'') is null or length(p_display_name)>100 then raise exception 'Display name must be 1 to 100 characters'; end if;
  update public.profile set display_name=btrim(p_display_name) where id=auth.uid();
end $$;

CREATE OR REPLACE FUNCTION public.redact_account_data(p_user_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_names text[];
begin
  if p_user_id is null then
    raise exception 'User ID is required';
  end if;

  -- Activity keeps display-name snapshots. Collect previous names before
  -- replacing them, including names changed since an event was recorded.
  select coalesce(array_agg(distinct name), '{}'::text[])
  into v_names
  from (
    select display_name as name from public.profile where id = p_user_id
    union all
    select actor_name from public.activity_event where actor_id = p_user_id
    union all
    select recipient_name from public.activity_event where recipient_id = p_user_id
  ) names
  where name is not null and name <> 'Deleted user';

  update public.profile
  set display_name = 'Deleted user', avatar_path = null, deleted_at = now()
  where id = p_user_id;
  if not found then
    raise exception 'Profile not found for account deletion';
  end if;


  update public.activity_event
  set actor_name = case when actor_id = p_user_id then 'Deleted user' else actor_name end,
      recipient_name = case when recipient_id = p_user_id then 'Deleted user' else recipient_name end,
      recipient_names = case when recipient_names && v_names then '{}'::text[] else recipient_names end
  where actor_id = p_user_id
     or recipient_id = p_user_id
     or recipient_names && v_names;

  -- Private expenses are visible only to this account. Shared transactions,
  -- shares and repayments remain intact for the other participants.
  delete from public.expense
  where created_by = p_user_id and not exists (select 1 from public.expense_share s where s.expense_id = expense.id and s.user_id <> p_user_id);
  update public.recurring_rule r set is_active=false,version=version+1
  where owner_user_id<>p_user_id and exists (
    select 1 from jsonb_array_elements(r.shares) s where (s->>'user_id')::uuid=p_user_id);
  delete from public.recurring_rule where owner_user_id = p_user_id;
  delete from public.activity_event where audience_user_id = p_user_id;
  delete from public.connection_invitation
  where created_by = p_user_id or invited_user_id = p_user_id;
  delete from public.expense_share_trust
  where user_id = p_user_id or trusted_user_id = p_user_id;
  delete from public.user_connection
  where user_a = p_user_id or user_b = p_user_id;
end;
$function$;

drop table public.household_member;
drop table public.household;
drop type public.household_role;
drop type public.settlement_mode;

drop function public.balance_snapshot();
CREATE OR REPLACE FUNCTION public.balance_snapshot()
 RETURNS TABLE(person_id uuid, display_name text, currency text, amount_minor bigint)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with obligations as (
    select case when e.paid_by = auth.uid() then s.user_id else e.paid_by end as other_id, e.currency,
      case when e.paid_by = auth.uid() then s.amount_minor else -s.amount_minor end as delta
    from public.expense e join public.expense_share s on s.expense_id = e.id
      join public.expense_share payer on payer.expense_id = e.id and payer.user_id = e.paid_by
    where public.current_account_is_active() and s.user_id <> e.paid_by and (e.paid_by = auth.uid() or s.user_id = auth.uid()) and s.status = 'accepted' and payer.status = 'accepted'
  ), payments as (
    select case when r.to_user = auth.uid() then r.from_user else r.to_user end as other_id, r.currency,
      case when r.to_user = auth.uid() then -r.amount_minor else r.amount_minor end as delta
    from public.repayment r where public.current_account_is_active() and auth.uid() in (r.from_user, r.to_user) and r.reversed_at is null
  ), net as (select other_id, currency, sum(delta)::bigint as amount_minor from (select * from obligations union all select * from payments) x group by other_id, currency)
  select n.other_id, coalesce(p.display_name, 'Connected person'), n.currency, n.amount_minor from net n join public.profile p on p.id = n.other_id where n.amount_minor <> 0
$function$;

CREATE OR REPLACE FUNCTION public.create_repayment(p_to_user_id uuid, p_amount_minor integer, p_currency text, p_note text, p_paid_at date, p_operation_id uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_id uuid; v_debt bigint;
begin
  if not public.current_account_is_active() or p_amount_minor <= 0 or p_to_user_id = auth.uid() or p_currency not in ('PLN','EUR','USD') then raise exception 'Invalid repayment'; end if;
  select id into v_id from public.repayment where operation_id = p_operation_id and from_user = auth.uid(); if v_id is not null then return v_id; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_to_user_id::text || p_currency, 0));
  if not public.current_account_is_active() then raise exception 'Account is closed'; end if;
  select -amount_minor into v_debt from public.balance_snapshot() where person_id = p_to_user_id and currency = p_currency;
  if coalesce(v_debt, 0) < p_amount_minor then raise exception 'Repayment exceeds confirmed debt'; end if;
  insert into public.repayment(from_user, to_user, amount_minor, currency, note, paid_at, operation_id) values (auth.uid(), p_to_user_id, p_amount_minor, p_currency, p_note, p_paid_at, p_operation_id) returning id into v_id;
  return v_id;
end $function$;
-- Invalid lookups return structured results so the attempt counter commits.
-- Throwing after incrementing would roll it back with the failed RPC.
drop function public.preview_connection_code(text);
drop function public.redeem_connection_code(text);
create function public.preview_connection_code(p_code text)
returns table(inviter_name text,error_code text)
language plpgsql security definer set search_path='' as $$
declare v_name text;
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  begin perform public.assert_connection_code_rate('attempt',10,interval '15 minutes');
  exception when raise_exception then return query select null::text,'rate_limited'::text; return; end;
  select p.display_name into v_name from public.connection_invitation i join public.profile p on p.id=i.created_by
    where i.code=public.normalized_connection_code(p_code) and i.accepted_at is null and i.expires_at>now() and p.deleted_at is null;
  if not found then return query select null::text,'unavailable'::text;
  else return query select coalesce(v_name,'Connected person'),null::text; end if;
end $$;
create function public.redeem_connection_code(p_code text)
returns table(user_id uuid,display_name text,error_code text)
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_inviter uuid; v_name text; v_code text:=public.normalized_connection_code(p_code);
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  begin perform public.assert_connection_code_rate('attempt',10,interval '15 minutes');
  exception when raise_exception then return query select null::uuid,null::text,'rate_limited'::text; return; end;
  select i.created_by,p.display_name into v_inviter,v_name from public.connection_invitation i join public.profile p on p.id=i.created_by
    where i.code=v_code and i.accepted_at is null and i.expires_at>now() and p.deleted_at is null for update of i;
  if not found or v_inviter=v_uid then return query select null::uuid,null::text,'unavailable'::text; return; end if;
  insert into public.user_connection(user_a,user_b,created_by,accepted_at)
    values(least(v_uid,v_inviter),greatest(v_uid,v_inviter),v_uid,now())
    on conflict(least(user_a,user_b),greatest(user_a,user_b)) do update set accepted_at=coalesce(user_connection.accepted_at,excluded.accepted_at);
  update public.connection_invitation set accepted_at=now(),invited_user_id=v_uid where code=v_code;
  return query select v_inviter,coalesce(v_name,'Connected person'),null::text;
end $$;

alter table public.connection_code_rate_limit add column id bigint generated always as identity primary key;
-- The counter is internal; keep it unexposed to API clients.
alter table public.connection_code_rate_limit set schema private;
create or replace function public.assert_connection_code_rate(p_action text,p_limit integer,p_window interval) returns void
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
 if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
 perform pg_advisory_xact_lock(hashtextextended(v_uid::text||':'||p_action,0));
 delete from private.connection_code_rate_limit where account_id=v_uid and occurred_at<now()-interval '1 day';
 if (select count(*) from private.connection_code_rate_limit where account_id=v_uid and action=p_action and occurred_at>now()-p_window)>=p_limit
   then raise exception 'Too many attempts. Please try again later.'; end if;
 insert into private.connection_code_rate_limit(account_id,action) values(v_uid,p_action);
end $$;

-- Restrict columns and payload sizes independently of the client UI.
alter table public.expense add constraint expense_text_bounds check(char_length(title)<=200 and char_length(note)<=5000);
alter table public.expense add constraint expense_location_object check(location is null or (jsonb_typeof(location)='object' and octet_length(location::text)<=8192));
alter table public.recurring_rule add constraint recurring_text_bounds check(char_length(title)<=200 and char_length(note)<=5000);
alter table public.recurring_rule add constraint recurring_location_object check(location is null or (jsonb_typeof(location)='object' and octet_length(location::text)<=8192));
alter table public.expense_edit_proposal add constraint proposal_text_bounds check(char_length(title)<=200 and char_length(note)<=5000 and char_length(message)<=5000);
alter table public.expense_edit_proposal add constraint proposal_location_object check(location is null or (jsonb_typeof(location)='object' and octet_length(location::text)<=8192));

create index expense_creator_date_idx on public.expense(created_by,spent_at desc);
create index recurring_owner_idx on public.recurring_rule(owner_user_id);
create index recurring_payer_idx on public.recurring_rule(paid_by);
create index activity_actor_idx on public.activity_event(actor_id);
create index activity_recipient_idx on public.activity_event(recipient_id);
create index proposal_proposer_idx on public.expense_edit_proposal(proposed_by);
create index proposal_payer_idx on public.expense_edit_proposal(paid_by);
create index trust_trusted_user_idx on public.expense_share_trust(trusted_user_id);
create index repayment_from_currency_idx on public.repayment(from_user,currency);
create index repayment_to_currency_idx on public.repayment(to_user,currency);
create index connection_user_b_idx on public.user_connection(user_b);
create index connection_creator_idx on public.user_connection(created_by);
create index invitation_creator_idx on public.connection_invitation(created_by);
create index invitation_recipient_idx on public.connection_invitation(invited_user_id);
drop index if exists public.expense_share_trust_user_idx; -- covered by the new unique pair

-- Cache caller-only expressions once per statement in remaining RLS policies.
do $$ declare r record; q text; c text; begin
 for r in select * from pg_policies where (schemaname='public' and tablename in ('profile','activity_event','user_connection','connection_invitation','repayment')) or schemaname='storage' loop
  q:=replace(replace(r.qual,'auth.uid()','(select auth.uid())'),'current_account_is_active()','(select public.current_account_is_active())');
  c:=replace(replace(r.with_check,'auth.uid()','(select auth.uid())'),'current_account_is_active()','(select public.current_account_is_active())');
  execute format('alter policy %I on %I.%I to authenticated%s%s',r.policyname,r.schemaname,r.tablename,
    case when q is null then '' else ' using ('||q||')' end,case when c is null then '' else ' with check ('||c||')' end);
 end loop;
end $$;

revoke all on all tables in schema public from public,anon;
revoke all on public.expense,public.expense_share,public.expense_edit_proposal,public.recurring_rule,public.expense_share_trust from authenticated;
grant select,delete on public.expense,public.recurring_rule to authenticated;
grant select on public.expense_share,public.expense_edit_proposal to authenticated;
grant select,insert,delete on public.expense_share_trust to authenticated;
revoke all on all functions in schema public from public,anon,authenticated;
revoke all on all functions in schema private from public,anon,authenticated;
grant execute on function private.can_read_expense_shares(uuid) to authenticated;
grant execute on function public.current_account_is_active(),public.are_connected(uuid,uuid),public.update_display_name(text),
 public.list_connections(),public.create_connection_invitation(),public.active_connection_invitation(),public.revoke_connection_invitation(),
 public.preview_connection_code(text),public.redeem_connection_code(text),public.balance_snapshot(),public.balance_history(uuid),
 public.create_repayment(uuid,integer,text,text,date,uuid),public.reverse_repayment(uuid,uuid),
 public.save_expense(jsonb,bigint),public.save_recurring_rule(jsonb,bigint),public.respond_to_expense_share(uuid,text),
 public.create_expense_edit_proposal(uuid,bigint,jsonb),public.respond_to_edit_proposal(uuid,boolean),public.activity_page(uuid) to authenticated;
alter default privileges for role postgres in schema public revoke all on tables from public,anon,authenticated;
alter default privileges for role postgres in schema public revoke execute on functions from public,anon,authenticated;
alter default privileges for role postgres in schema private revoke execute on functions from public,anon,authenticated;
notify pgrst,'reload schema';
