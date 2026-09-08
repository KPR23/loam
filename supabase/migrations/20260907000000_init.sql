-- Loam MVP schema + RLS
-- Apply in Supabase SQL editor or via CLI: supabase db push
-- Amounts are always integer minor units (grosze). Expense dates use `date` (not timestamptz) for day aggregation.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

do $$ begin
  create type public.settlement_mode as enum ('shared', 'ledger');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.household_role as enum ('owner', 'member');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.expense_category as enum (
    'groceries', 'dining', 'transport', 'housing', 'utilities',
    'health', 'entertainment', 'shopping', 'travel', 'other'
  );
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- Profiles (optional display mirror of auth.users)
-- ---------------------------------------------------------------------------

create table if not exists public.profile (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now()
);

alter table public.profile enable row level security;

create policy "profile_select_own"
  on public.profile for select
  using (auth.uid() = id);

create policy "profile_update_own"
  on public.profile for update
  using (auth.uid() = id)
  with check (auth.uid() = id);

create policy "profile_insert_own"
  on public.profile for insert
  with check (auth.uid() = id);

-- Auto-create profile on signup
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profile (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(new.email, '@', 1))
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Recurring (table exists for 1.1; no UI in MVP)
-- ---------------------------------------------------------------------------

create table if not exists public.recurring_rule (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null references auth.users (id) on delete cascade,
  household_id uuid, -- FK added after household exists
  amount_minor integer not null check (amount_minor > 0),
  currency text not null default 'PLN',
  category public.expense_category not null default 'other',
  note text,
  interval_unit text not null check (interval_unit in ('day', 'week', 'month', 'year')),
  interval_count integer not null default 1 check (interval_count > 0),
  next_occurrence date not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Household
-- ---------------------------------------------------------------------------

create table if not exists public.household (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  currency text not null default 'PLN',
  settlement_mode public.settlement_mode not null default 'ledger',
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now()
);

create table if not exists public.household_member (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.household (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  display_name text not null,
  role public.household_role not null default 'member',
  joined_at timestamptz not null default now(),
  unique (household_id, user_id)
);

create table if not exists public.household_invite (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.household (id) on delete cascade,
  code text not null unique,
  created_by uuid not null references auth.users (id),
  expires_at timestamptz not null,
  consumed_by uuid references auth.users (id),
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

-- Deferred FK for recurring_rule.household_id
do $$ begin
  alter table public.recurring_rule
    add constraint recurring_rule_household_id_fkey
    foreign key (household_id) references public.household (id) on delete set null;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- Expenses + shares
-- ---------------------------------------------------------------------------

create table if not exists public.expense (
  id uuid primary key default gen_random_uuid(),
  amount_minor integer not null check (amount_minor > 0),
  currency text not null default 'PLN',
  category public.expense_category not null default 'other',
  note text,
  spent_at date not null default (timezone('utc', now()))::date,
  paid_by uuid not null references auth.users (id),
  created_by uuid not null references auth.users (id),
  household_id uuid references public.household (id) on delete cascade,
  -- null household_id = private personal expense
  recurring_id uuid references public.recurring_rule (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists expense_spent_at_idx on public.expense (spent_at);
create index if not exists expense_paid_by_idx on public.expense (paid_by);
create index if not exists expense_household_id_idx on public.expense (household_id);

create table if not exists public.expense_share (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expense (id) on delete cascade,
  user_id uuid not null references auth.users (id),
  amount_minor integer not null check (amount_minor >= 0),
  unique (expense_id, user_id)
);

create index if not exists expense_share_user_id_idx on public.expense_share (user_id);

-- Share sum must equal expense amount (enforced via trigger)
create or replace function public.enforce_expense_share_sum()
returns trigger
language plpgsql
as $$
declare
  total integer;
  share_sum integer;
begin
  select e.amount_minor into total
  from public.expense e
  where e.id = coalesce(new.expense_id, old.expense_id);

  select coalesce(sum(s.amount_minor), 0) into share_sum
  from public.expense_share s
  where s.expense_id = coalesce(new.expense_id, old.expense_id);

  if share_sum <> total then
    raise exception 'expense_share sum (%) must equal expense.amount_minor (%)', share_sum, total;
  end if;

  return null;
end;
$$;

drop trigger if exists expense_share_sum_check on public.expense_share;
create constraint trigger expense_share_sum_check
  after insert or update or delete on public.expense_share
  deferrable initially deferred
  for each row execute function public.enforce_expense_share_sum();

-- ---------------------------------------------------------------------------
-- Settlements (ledger mode only, app-enforced)
-- ---------------------------------------------------------------------------

create table if not exists public.settlement (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.household (id) on delete cascade,
  from_user uuid not null references auth.users (id),
  to_user uuid not null references auth.users (id),
  amount_minor integer not null check (amount_minor > 0),
  note text,
  settled_at date not null default (timezone('utc', now()))::date,
  created_by uuid not null references auth.users (id),
  created_at timestamptz not null default now(),
  check (from_user <> to_user)
);

-- ---------------------------------------------------------------------------
-- Helpers for RLS
-- ---------------------------------------------------------------------------

create or replace function public.is_household_member(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.household_member m
    where m.household_id = hid and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_household_owner(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.household_member m
    where m.household_id = hid
      and m.user_id = auth.uid()
      and m.role = 'owner'
  );
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.household enable row level security;
alter table public.household_member enable row level security;
alter table public.household_invite enable row level security;
alter table public.expense enable row level security;
alter table public.expense_share enable row level security;
alter table public.settlement enable row level security;
alter table public.recurring_rule enable row level security;

-- Household
create policy "household_select_member"
  on public.household for select
  using (public.is_household_member(id));

create policy "household_insert_authenticated"
  on public.household for insert
  with check (auth.uid() = created_by);

create policy "household_update_owner"
  on public.household for update
  using (public.is_household_owner(id))
  with check (public.is_household_owner(id));

create policy "household_delete_owner"
  on public.household for delete
  using (public.is_household_owner(id));

-- Members
create policy "member_select_same_household"
  on public.household_member for select
  using (public.is_household_member(household_id));

create policy "member_insert_owner_or_self_join"
  on public.household_member for insert
  with check (
    auth.uid() = user_id
    or public.is_household_owner(household_id)
  );

create policy "member_update_owner"
  on public.household_member for update
  using (public.is_household_owner(household_id));

create policy "member_delete_owner_or_self"
  on public.household_member for delete
  using (
    auth.uid() = user_id
    or public.is_household_owner(household_id)
  );

-- Invites
create policy "invite_select_member"
  on public.household_invite for select
  using (public.is_household_member(household_id));

create policy "invite_insert_owner"
  on public.household_invite for insert
  with check (public.is_household_owner(household_id) and auth.uid() = created_by);

create policy "invite_update_member_or_owner"
  on public.household_invite for update
  using (
    public.is_household_owner(household_id)
    or (consumed_by is null and expires_at > now())
  );

-- Expenses: private (household_id null, created_by = me) OR household member
create policy "expense_select_own_or_household"
  on public.expense for select
  using (
    (household_id is null and created_by = auth.uid())
    or (household_id is not null and public.is_household_member(household_id))
  );

create policy "expense_insert_own_or_household"
  on public.expense for insert
  with check (
    created_by = auth.uid()
    and paid_by = auth.uid() -- MVP: only log what you paid; relax later if needed
    and (
      household_id is null
      or public.is_household_member(household_id)
    )
  );

create policy "expense_update_creator"
  on public.expense for update
  using (
    created_by = auth.uid()
    and (
      household_id is null
      or public.is_household_member(household_id)
    )
  );

create policy "expense_delete_creator"
  on public.expense for delete
  using (created_by = auth.uid());

-- Shares: visible if parent expense is visible
create policy "share_select_via_expense"
  on public.expense_share for select
  using (
    exists (
      select 1 from public.expense e
      where e.id = expense_id
        and (
          (e.household_id is null and e.created_by = auth.uid())
          or (e.household_id is not null and public.is_household_member(e.household_id))
        )
    )
  );

create policy "share_insert_via_expense"
  on public.expense_share for insert
  with check (
    exists (
      select 1 from public.expense e
      where e.id = expense_id
        and e.created_by = auth.uid()
    )
  );

create policy "share_update_via_expense"
  on public.expense_share for update
  using (
    exists (
      select 1 from public.expense e
      where e.id = expense_id and e.created_by = auth.uid()
    )
  );

create policy "share_delete_via_expense"
  on public.expense_share for delete
  using (
    exists (
      select 1 from public.expense e
      where e.id = expense_id and e.created_by = auth.uid()
    )
  );

-- Settlements
create policy "settlement_select_member"
  on public.settlement for select
  using (public.is_household_member(household_id));

create policy "settlement_insert_member"
  on public.settlement for insert
  with check (
    public.is_household_member(household_id)
    and created_by = auth.uid()
    and (from_user = auth.uid() or to_user = auth.uid())
  );

-- Recurring (owner only until 1.1 household support in UI)
create policy "recurring_owner_all"
  on public.recurring_rule for all
  using (owner_user_id = auth.uid())
  with check (owner_user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Views
-- ---------------------------------------------------------------------------

-- Personal month cost = sum of my shares (tracker home metric)
create or replace view public.v_personal_month_spend as
select
  s.user_id,
  date_trunc('month', e.spent_at::timestamp)::date as month_start,
  e.currency,
  sum(s.amount_minor)::integer as spent_minor,
  sum(s.amount_minor) filter (where e.household_id is not null)::integer as shared_share_minor
from public.expense_share s
join public.expense e on e.id = s.expense_id
group by s.user_id, date_trunc('month', e.spent_at::timestamp)::date, e.currency;

-- Ledger balances: net = paid − share (+ settlements received − settlements sent)
create or replace view public.v_household_balances as
with paid as (
  select household_id, paid_by as user_id, sum(amount_minor)::integer as paid_minor
  from public.expense
  where household_id is not null
  group by household_id, paid_by
),
shares as (
  select e.household_id, s.user_id, sum(s.amount_minor)::integer as share_minor
  from public.expense_share s
  join public.expense e on e.id = s.expense_id
  where e.household_id is not null
  group by e.household_id, s.user_id
),
settled_out as (
  select household_id, from_user as user_id, sum(amount_minor)::integer as out_minor
  from public.settlement
  group by household_id, from_user
),
settled_in as (
  select household_id, to_user as user_id, sum(amount_minor)::integer as in_minor
  from public.settlement
  group by household_id, to_user
),
users as (
  select household_id, user_id from paid
  union
  select household_id, user_id from shares
  union
  select household_id, user_id from settled_out
  union
  select household_id, user_id from settled_in
)
select
  u.household_id,
  u.user_id,
  coalesce(p.paid_minor, 0) as paid_minor,
  coalesce(sh.share_minor, 0) as share_minor,
  coalesce(si.in_minor, 0) as settled_in_minor,
  coalesce(so.out_minor, 0) as settled_out_minor,
  (
    coalesce(p.paid_minor, 0)
    - coalesce(sh.share_minor, 0)
    + coalesce(si.in_minor, 0)
    - coalesce(so.out_minor, 0)
  )::integer as net_minor
from users u
left join paid p on p.household_id = u.household_id and p.user_id = u.user_id
left join shares sh on sh.household_id = u.household_id and sh.user_id = u.user_id
left join settled_in si on si.household_id = u.household_id and si.user_id = u.user_id
left join settled_out so on so.household_id = u.household_id and so.user_id = u.user_id;

-- ---------------------------------------------------------------------------
-- Privileges (required for PostgREST; RLS still filters rows)
-- Without these, clients get "permission denied for table …" and nested
-- embeds like expense_share are missing from the schema cache.
-- ---------------------------------------------------------------------------

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

-- Note: views use underlying table RLS in Postgres when queried as invoker (default in Supabase).
