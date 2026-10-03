-- Complete the server-owned activity history for mutations that do not touch
-- an expense_share status. These triggers cover direct REST mutations and RPCs.

-- Keep the oldest row if an earlier client race already produced duplicates.
delete from public.expense e
using public.expense duplicate
where e.recurring_id is not null
  and e.recurring_id = duplicate.recurring_id
  and e.spent_at = duplicate.spent_at
  and (e.created_at, e.id) > (duplicate.created_at, duplicate.id);

create unique index if not exists expense_recurring_occurrence_unique_idx
  on public.expense (recurring_id, spent_at)
  where recurring_id is not null;

create or replace function public.log_expense_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_kind text;
  v_actor uuid := auth.uid();
begin
  if old.household_id is null and new.household_id is null then return new; end if;
  v_kind := 'edited';
  insert into public.activity_event (
    audience_user_id, kind, actor_id, actor_name, expense_id, expense_title,
    category, affected_share_minor, expense_total_minor, currency
  )
  select distinct s.user_id, v_kind, coalesce(v_actor, new.created_by),
    public.activity_name(coalesce(v_actor, new.created_by)), new.id,
    coalesce(new.title, initcap(new.category::text)), new.category,
    s.amount_minor, new.amount_minor, new.currency
  from public.expense_share s
  where s.expense_id = new.id
    and s.user_id <> new.created_by
    and new.household_id is not null;
  insert into public.activity_event (
    audience_user_id, kind, actor_id, actor_name, expense_id, expense_title,
    category, affected_share_minor, expense_total_minor, currency
  )
  select new.created_by, v_kind, coalesce(v_actor, new.created_by),
    public.activity_name(coalesce(v_actor, new.created_by)), new.id,
    coalesce(new.title, initcap(new.category::text)), new.category,
    new.amount_minor, new.amount_minor, new.currency
  where new.household_id is not null;
  return new;
end;
$$;

create or replace function public.log_deleted_expense_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor uuid := auth.uid();
begin
  if old.household_id is null then return old; end if;
  insert into public.activity_event (
    audience_user_id, kind, actor_id, actor_name, expense_id, expense_title,
    category, affected_share_minor, expense_total_minor, currency
  )
  select distinct s.user_id, 'deleted', coalesce(v_actor, old.created_by),
    public.activity_name(coalesce(v_actor, old.created_by)), old.id,
    coalesce(old.title, initcap(old.category::text)), old.category,
    s.amount_minor, old.amount_minor, old.currency
  from public.expense_share s where s.expense_id = old.id and s.user_id <> old.created_by;
  insert into public.activity_event (
    audience_user_id, kind, actor_id, actor_name, expense_id, expense_title,
    category, affected_share_minor, expense_total_minor, currency
  ) values (old.created_by, 'deleted', coalesce(v_actor, old.created_by),
    public.activity_name(coalesce(v_actor, old.created_by)), old.id,
    coalesce(old.title, initcap(old.category::text)), old.category,
    old.amount_minor, old.amount_minor, old.currency);
  return old;
end;
$$;

create or replace function public.log_removed_share_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_expense public.expense%rowtype; v_actor uuid := auth.uid();
begin
  -- Defer until commit so the share-replacement RPC can reinsert retained
  -- participants before we decide whether this row was really removed.
  select * into v_expense from public.expense where id = old.expense_id;
  if v_expense.id is null or v_expense.household_id is null
     or old.user_id = v_expense.created_by then return old; end if;
  if exists (
    select 1 from public.expense_share s
    where s.expense_id = old.expense_id and s.user_id = old.user_id
  ) then return old; end if;
  insert into public.activity_event (
    audience_user_id, kind, actor_id, actor_name, recipient_id, recipient_name,
    expense_id, expense_title, category, affected_share_minor,
    expense_total_minor, currency
  )
  select audience.user_id, 'participant_removed', coalesce(v_actor, v_expense.created_by),
    public.activity_name(coalesce(v_actor, v_expense.created_by)), old.user_id,
    public.activity_name(old.user_id), v_expense.id,
    coalesce(v_expense.title, initcap(v_expense.category::text)), v_expense.category,
    old.amount_minor, v_expense.amount_minor, v_expense.currency
  from (select v_expense.created_by as user_id
        union select s.user_id from public.expense_share s
        where s.expense_id = old.expense_id and s.user_id <> old.user_id) audience;
  return old;
end;
$$;

create or replace function public.log_proposal_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_expense public.expense%rowtype; v_kind text; v_actor uuid;
begin
  select * into v_expense from public.expense where id = new.expense_id;
  if v_expense.id is null or v_expense.household_id is null then return new; end if;
  if tg_op = 'INSERT' then
    v_kind := 'proposal_created'; v_actor := new.proposed_by;
  elsif old.status = new.status or new.status not in ('accepted', 'rejected') then
    return new;
  else
    v_kind := case when new.status = 'accepted' then 'proposal_accepted' else 'proposal_rejected' end;
    v_actor := coalesce(auth.uid(), v_expense.created_by);
  end if;
  insert into public.activity_event (
    audience_user_id, kind, actor_id, actor_name, recipient_id, recipient_name,
    expense_id, expense_title, category, affected_share_minor,
    expense_total_minor, currency
  )
  select audience.user_id, v_kind, v_actor, public.activity_name(v_actor),
    case when v_kind = 'proposal_created' then v_expense.created_by else new.proposed_by end,
    public.activity_name(case when v_kind = 'proposal_created' then v_expense.created_by else new.proposed_by end),
    v_expense.id, coalesce(v_expense.title, initcap(v_expense.category::text)),
    v_expense.category, v_expense.amount_minor, v_expense.amount_minor, v_expense.currency
  from (select v_expense.created_by as user_id
        union select s.user_id from public.expense_share s where s.expense_id = new.expense_id) audience;
  return new;
end;
$$;

drop trigger if exists activity_expense_edited on public.expense;
create trigger activity_expense_edited after update on public.expense
for each row execute function public.log_expense_activity();
drop trigger if exists activity_expense_deleted on public.expense;
create trigger activity_expense_deleted before delete on public.expense
for each row execute function public.log_deleted_expense_activity();
drop trigger if exists activity_share_removed on public.expense_share;
create constraint trigger activity_share_removed after delete on public.expense_share
deferrable initially deferred
for each row execute function public.log_removed_share_activity();
drop trigger if exists activity_proposal_created on public.expense_edit_proposal;
create trigger activity_proposal_created after insert on public.expense_edit_proposal
for each row execute function public.log_proposal_activity();
drop trigger if exists activity_proposal_status on public.expense_edit_proposal;
create trigger activity_proposal_status after update of status on public.expense_edit_proposal
for each row execute function public.log_proposal_activity();

revoke all on function public.log_expense_activity() from public;
revoke all on function public.log_deleted_expense_activity() from public;
revoke all on function public.log_removed_share_activity() from public;
revoke all on function public.log_proposal_activity() from public;
notify pgrst, 'reload schema';
