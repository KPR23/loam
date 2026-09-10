-- Shared expense acceptance: participants must accept their share before it counts
-- toward monthly totals. Supports trust (auto-accept from a person) and edit proposals.

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

do $$ begin
  create type public.expense_share_status as enum ('pending', 'accepted', 'rejected');
exception when duplicate_object then null;
end $$;

do $$ begin
  create type public.expense_proposal_status as enum ('pending', 'accepted', 'rejected', 'withdrawn');
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
-- expense_share: acceptance status per participant
-- ---------------------------------------------------------------------------

alter table public.expense_share
  add column if not exists status public.expense_share_status not null default 'accepted',
  add column if not exists responded_at timestamptz,
  add column if not exists accepted_via_trust boolean not null default false;

-- Existing shares were implicitly accepted.
update public.expense_share set status = 'accepted' where status is distinct from 'accepted';

-- ---------------------------------------------------------------------------
-- Auto-trust: user trusts another household member's shared expenses
-- ---------------------------------------------------------------------------

create table if not exists public.expense_share_trust (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.household (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  trusted_user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (household_id, user_id, trusted_user_id),
  check (user_id <> trusted_user_id)
);

create index if not exists expense_share_trust_user_idx
  on public.expense_share_trust (user_id, trusted_user_id);

-- ---------------------------------------------------------------------------
-- Edit proposals: non-creator suggests changes; creator must accept
-- ---------------------------------------------------------------------------

create table if not exists public.expense_edit_proposal (
  id uuid primary key default gen_random_uuid(),
  expense_id uuid not null references public.expense (id) on delete cascade,
  proposed_by uuid not null references auth.users (id),
  status public.expense_proposal_status not null default 'pending',
  amount_minor integer not null check (amount_minor > 0),
  category public.expense_category not null,
  note text,
  spent_at date not null,
  paid_by uuid not null references auth.users (id),
  shares jsonb not null,
  message text,
  created_at timestamptz not null default now(),
  responded_at timestamptz
);

create index if not exists expense_edit_proposal_expense_idx
  on public.expense_edit_proposal (expense_id);

create unique index if not exists expense_edit_proposal_one_pending
  on public.expense_edit_proposal (expense_id, proposed_by)
  where status = 'pending';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function public.share_status_for_insert(
  p_expense_id uuid,
  p_user_id uuid
)
returns public.expense_share_status
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_created_by uuid;
  v_household_id uuid;
begin
  select e.created_by, e.household_id
  into v_created_by, v_household_id
  from public.expense e
  where e.id = p_expense_id;

  if v_created_by is null then
    return 'accepted';
  end if;

  -- Personal expenses or creator's own share are always accepted.
  if v_household_id is null or p_user_id = v_created_by then
    return 'accepted';
  end if;

  -- Auto-accept when participant trusts the creator.
  if exists (
    select 1
    from public.expense_share_trust t
    where t.household_id = v_household_id
      and t.user_id = p_user_id
      and t.trusted_user_id = v_created_by
  ) then
    return 'accepted';
  end if;

  return 'pending';
end;
$$;

create or replace function public.set_expense_share_status_on_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  new.status := public.share_status_for_insert(new.expense_id, new.user_id);
  if new.status = 'accepted' and new.user_id <> (
    select e.created_by from public.expense e where e.id = new.expense_id
  ) then
    new.accepted_via_trust := true;
    new.responded_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists expense_share_set_status on public.expense_share;
create trigger expense_share_set_status
  before insert on public.expense_share
  for each row execute function public.set_expense_share_status_on_insert();

-- ---------------------------------------------------------------------------
-- RPC: respond to a pending share (accept / reject / accept with trust)
-- ---------------------------------------------------------------------------

create or replace function public.respond_to_expense_share(
  p_expense_id uuid,
  p_action text
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_share public.expense_share%rowtype;
  v_expense public.expense%rowtype;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if p_action not in ('accept', 'reject', 'accept_with_trust') then
    raise exception 'Invalid action';
  end if;

  select * into v_expense
  from public.expense e
  where e.id = p_expense_id;

  if v_expense.id is null then
    raise exception 'Expense not found';
  end if;

  select * into v_share
  from public.expense_share s
  where s.expense_id = p_expense_id
    and s.user_id = v_user_id;

  if v_share.id is null then
    raise exception 'Share not found';
  end if;

  if v_share.status <> 'pending' then
    raise exception 'Share is not pending';
  end if;

  if p_action = 'reject' then
    update public.expense_share
    set status = 'rejected', responded_at = now()
    where id = v_share.id;
    return;
  end if;

  update public.expense_share
  set status = 'accepted', responded_at = now(), accepted_via_trust = false
  where id = v_share.id;

  if p_action = 'accept_with_trust' and v_expense.household_id is not null then
    insert into public.expense_share_trust (household_id, user_id, trusted_user_id)
    values (v_expense.household_id, v_user_id, v_expense.created_by)
    on conflict (household_id, user_id, trusted_user_id) do nothing;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: propose edits to a shared expense (non-creator)
-- ---------------------------------------------------------------------------

create or replace function public.create_expense_edit_proposal(
  p_expense_id uuid,
  p_amount_minor integer,
  p_category public.expense_category,
  p_note text,
  p_spent_at date,
  p_paid_by uuid,
  p_shares jsonb,
  p_message text default null
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_expense public.expense%rowtype;
  v_share_sum integer;
  v_proposal_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_expense
  from public.expense e
  where e.id = p_expense_id;

  if v_expense.id is null or v_expense.household_id is null then
    raise exception 'Expense not found';
  end if;

  if v_expense.created_by = v_user_id then
    raise exception 'Creator cannot propose edits to own expense';
  end if;

  if not exists (
    select 1 from public.expense_share s
    where s.expense_id = p_expense_id and s.user_id = v_user_id
  ) then
    raise exception 'Not a participant';
  end if;

  select coalesce(sum((elem->>'amount_minor')::integer), 0)
  into v_share_sum
  from jsonb_array_elements(p_shares) as elem;

  if v_share_sum <> p_amount_minor then
    raise exception 'Shares must sum to expense total';
  end if;

  -- Withdraw any previous pending proposal from this user.
  update public.expense_edit_proposal
  set status = 'withdrawn', responded_at = now()
  where expense_id = p_expense_id
    and proposed_by = v_user_id
    and status = 'pending';

  insert into public.expense_edit_proposal (
    expense_id, proposed_by, amount_minor, category, note,
    spent_at, paid_by, shares, message
  )
  values (
    p_expense_id, v_user_id, p_amount_minor, p_category, p_note,
    p_spent_at, p_paid_by, p_shares, p_message
  )
  returning id into v_proposal_id;

  return v_proposal_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- RPC: creator responds to an edit proposal
-- ---------------------------------------------------------------------------

create or replace function public.respond_to_edit_proposal(
  p_proposal_id uuid,
  p_accept boolean
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_proposal public.expense_edit_proposal%rowtype;
  v_expense public.expense%rowtype;
  v_share jsonb;
  v_status public.expense_share_status;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_proposal
  from public.expense_edit_proposal p
  where p.id = p_proposal_id;

  if v_proposal.id is null or v_proposal.status <> 'pending' then
    raise exception 'Proposal not found';
  end if;

  select * into v_expense
  from public.expense e
  where e.id = v_proposal.expense_id;

  if v_expense.created_by <> v_user_id then
    raise exception 'Only creator can respond';
  end if;

  if not p_accept then
    update public.expense_edit_proposal
    set status = 'rejected', responded_at = now()
    where id = p_proposal_id;
    return;
  end if;

  update public.expense
  set
    amount_minor = v_proposal.amount_minor,
    category = v_proposal.category,
    note = v_proposal.note,
    spent_at = v_proposal.spent_at,
    paid_by = v_proposal.paid_by,
    updated_at = now()
  where id = v_proposal.expense_id;

  delete from public.expense_share
  where expense_id = v_proposal.expense_id;

  for v_share in select * from jsonb_array_elements(v_proposal.shares)
  loop
    v_status := public.share_status_for_insert(
      v_proposal.expense_id,
      (v_share->>'user_id')::uuid
    );

    insert into public.expense_share (expense_id, user_id, amount_minor, status, responded_at, accepted_via_trust)
    values (
      v_proposal.expense_id,
      (v_share->>'user_id')::uuid,
      (v_share->>'amount_minor')::integer,
      v_status,
      case when v_status = 'accepted' then now() else null end,
      v_status = 'accepted' and (v_share->>'user_id')::uuid <> v_expense.created_by
    );
  end loop;

  update public.expense_edit_proposal
  set status = 'accepted', responded_at = now()
  where id = p_proposal_id;

  -- Reject other pending proposals for this expense.
  update public.expense_edit_proposal
  set status = 'rejected', responded_at = now()
  where expense_id = v_proposal.expense_id
    and id <> p_proposal_id
    and status = 'pending';
end;
$$;

-- ---------------------------------------------------------------------------
-- Update atomic share replacement to preserve acceptance rules
-- ---------------------------------------------------------------------------

create or replace function public.update_expense_with_shares(
  p_expense_id uuid,
  p_amount_minor integer,
  p_currency text,
  p_category public.expense_category,
  p_note text,
  p_spent_at date,
  p_paid_by uuid,
  p_household_id uuid,
  p_recurring_id uuid,
  p_shares jsonb
)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_share_sum integer := 0;
  v_share jsonb;
  v_status public.expense_share_status;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1
    from public.expense e
    where e.id = p_expense_id
      and e.created_by = v_user_id
  ) then
    raise exception 'Expense not found or not allowed';
  end if;

  select coalesce(sum((elem->>'amount_minor')::integer), 0)
  into v_share_sum
  from jsonb_array_elements(p_shares) as elem;

  if v_share_sum <> p_amount_minor then
    raise exception 'Shares must sum to expense total';
  end if;

  update public.expense
  set
    amount_minor = p_amount_minor,
    currency = p_currency,
    category = p_category,
    note = p_note,
    spent_at = p_spent_at,
    paid_by = p_paid_by,
    household_id = p_household_id,
    recurring_id = p_recurring_id,
    updated_at = now()
  where id = p_expense_id;

  delete from public.expense_share
  where expense_id = p_expense_id;

  for v_share in select * from jsonb_array_elements(p_shares)
  loop
    v_status := public.share_status_for_insert(
      p_expense_id,
      (v_share->>'user_id')::uuid
    );

    insert into public.expense_share (expense_id, user_id, amount_minor, status, responded_at, accepted_via_trust)
    values (
      p_expense_id,
      (v_share->>'user_id')::uuid,
      (v_share->>'amount_minor')::integer,
      v_status,
      case when v_status = 'accepted' then now() else null end,
      v_status = 'accepted' and (v_share->>'user_id')::uuid <> v_user_id
    );
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------

alter table public.expense_share_trust enable row level security;
alter table public.expense_edit_proposal enable row level security;

create policy "trust_select_own"
  on public.expense_share_trust for select
  using (user_id = auth.uid());

create policy "trust_insert_own"
  on public.expense_share_trust for insert
  with check (
    user_id = auth.uid()
    and public.is_household_member(household_id)
  );

create policy "trust_delete_own"
  on public.expense_share_trust for delete
  using (user_id = auth.uid());

-- Participants can update their own share status (accept/reject).
create policy "share_update_own_acceptance"
  on public.expense_share for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "proposal_select_participant"
  on public.expense_edit_proposal for select
  using (
    proposed_by = auth.uid()
    or exists (
      select 1 from public.expense e
      where e.id = expense_id and e.created_by = auth.uid()
    )
  );

create policy "proposal_insert_participant"
  on public.expense_edit_proposal for insert
  with check (
    proposed_by = auth.uid()
    and exists (
      select 1 from public.expense e
      where e.id = expense_id
        and e.household_id is not null
        and e.created_by <> auth.uid()
        and exists (
          select 1 from public.expense_share s
          where s.expense_id = e.id and s.user_id = auth.uid()
        )
    )
  );

create policy "proposal_update_creator"
  on public.expense_edit_proposal for update
  using (
    exists (
      select 1 from public.expense e
      where e.id = expense_id and e.created_by = auth.uid()
    )
    or proposed_by = auth.uid()
  );

-- ---------------------------------------------------------------------------
-- View: only accepted shares count toward monthly spend
-- ---------------------------------------------------------------------------

create or replace view public.v_personal_month_spend as
select
  s.user_id,
  date_trunc('month', e.spent_at::timestamp)::date as month_start,
  e.currency,
  sum(s.amount_minor) filter (where s.status = 'accepted')::integer as spent_minor,
  sum(s.amount_minor) filter (where e.household_id is not null and s.status = 'accepted')::integer as shared_share_minor
from public.expense_share s
join public.expense e on e.id = s.expense_id
group by s.user_id, date_trunc('month', e.spent_at::timestamp)::date, e.currency;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------

grant select, insert, delete on public.expense_share_trust to authenticated;
grant select, insert, update on public.expense_edit_proposal to authenticated;

grant execute on function public.respond_to_expense_share(uuid, text) to authenticated;
grant execute on function public.create_expense_edit_proposal(uuid, integer, public.expense_category, text, date, uuid, jsonb, text) to authenticated;
grant execute on function public.respond_to_edit_proposal(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
