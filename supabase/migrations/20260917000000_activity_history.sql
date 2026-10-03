-- Immutable, server-owned shared-expense history. There is intentionally no
-- client insert/update/delete policy: events can only be created by mutations.

create table if not exists public.activity_event (
  id uuid primary key default gen_random_uuid(),
  audience_user_id uuid not null references auth.users(id) on delete cascade,
  occurred_at timestamptz not null default now(),
  kind text not null check (kind in ('shared','accepted','rejected','edited','participant_removed','deleted','proposal_created','proposal_accepted','proposal_rejected','auto_accepted','proposal_superseded')),
  actor_id uuid not null references auth.users(id),
  actor_name text not null,
  recipient_id uuid references auth.users(id),
  recipient_name text,
  expense_id uuid,
  expense_title text not null,
  category public.expense_category not null,
  affected_share_minor integer not null,
  expense_total_minor integer not null,
  currency text not null
);

create index if not exists activity_event_audience_cursor_idx
  on public.activity_event (audience_user_id, occurred_at desc, id desc);

alter table public.activity_event enable row level security;
drop policy if exists "activity_select_audience" on public.activity_event;
create policy "activity_select_audience" on public.activity_event for select using (audience_user_id = auth.uid());

create or replace function public.activity_name(p_user_id uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select display_name from public.household_member where user_id = p_user_id order by joined_at desc limit 1),
                  (select display_name from public.profile where id = p_user_id), 'Someone');
$$;

create or replace function public.log_share_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_expense public.expense%rowtype; v_kind text;
begin
  select * into v_expense from public.expense where id = new.expense_id;
  if v_expense.household_id is null or new.user_id = v_expense.created_by then return new; end if;
  v_kind := case when new.status = 'accepted' and new.accepted_via_trust then 'auto_accepted' else 'shared' end;
  insert into public.activity_event (audience_user_id, kind, actor_id, actor_name, recipient_id, recipient_name, expense_id, expense_title, category, affected_share_minor, expense_total_minor, currency)
  values (new.user_id, v_kind, v_expense.created_by, public.activity_name(v_expense.created_by), new.user_id, public.activity_name(new.user_id), v_expense.id, coalesce(v_expense.title, initcap(v_expense.category::text)), v_expense.category, new.amount_minor, v_expense.amount_minor, v_expense.currency),
         (v_expense.created_by, v_kind, v_expense.created_by, public.activity_name(v_expense.created_by), new.user_id, public.activity_name(new.user_id), v_expense.id, coalesce(v_expense.title, initcap(v_expense.category::text)), v_expense.category, new.amount_minor, v_expense.amount_minor, v_expense.currency);
  return new;
end;
$$;

create or replace function public.log_share_response_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_expense public.expense%rowtype; v_kind text;
begin
  if old.status = new.status or new.status not in ('accepted','rejected') then return new; end if;
  select * into v_expense from public.expense where id = new.expense_id;
  if v_expense.household_id is null then return new; end if;
  v_kind := case when new.status = 'accepted' then 'accepted' else 'rejected' end;
  insert into public.activity_event (audience_user_id, kind, actor_id, actor_name, recipient_id, recipient_name, expense_id, expense_title, category, affected_share_minor, expense_total_minor, currency)
  values (new.user_id, v_kind, new.user_id, public.activity_name(new.user_id), v_expense.created_by, public.activity_name(v_expense.created_by), v_expense.id, coalesce(v_expense.title, initcap(v_expense.category::text)), v_expense.category, new.amount_minor, v_expense.amount_minor, v_expense.currency),
         (v_expense.created_by, v_kind, new.user_id, public.activity_name(new.user_id), v_expense.created_by, public.activity_name(v_expense.created_by), v_expense.id, coalesce(v_expense.title, initcap(v_expense.category::text)), v_expense.category, new.amount_minor, v_expense.amount_minor, v_expense.currency);
  return new;
end;
$$;

drop trigger if exists activity_share_created on public.expense_share;
create trigger activity_share_created after insert on public.expense_share for each row execute function public.log_share_activity();
drop trigger if exists activity_share_responded on public.expense_share;
create trigger activity_share_responded after update of status on public.expense_share for each row execute function public.log_share_response_activity();

revoke all on public.activity_event from anon, authenticated;
grant select on public.activity_event to authenticated;
revoke all on function public.activity_name(uuid) from public;
notify pgrst, 'reload schema';
