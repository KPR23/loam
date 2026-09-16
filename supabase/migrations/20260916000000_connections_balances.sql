-- Connections replace the debug/test-household prerequisite for sharing.
-- Amounts remain integer grosze and balances are always pairwise.

create table if not exists public.user_connection (
  id uuid primary key default gen_random_uuid(),
  user_a uuid not null references auth.users(id) on delete cascade,
  user_b uuid not null references auth.users(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  check (user_a <> user_b),
  unique (user_a, user_b)
);

create table if not exists public.connection_invitation (
  id uuid primary key default gen_random_uuid(),
  -- pgcrypto's UUID generator is available on every supported Supabase
  -- Postgres build; using it avoids the optional gen_random_bytes function.
  code text not null unique default replace(gen_random_uuid()::text, '-', ''),
  created_by uuid not null references auth.users(id) on delete cascade,
  invited_user_id uuid references auth.users(id) on delete cascade,
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.repayment (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references auth.users(id),
  to_user uuid not null references auth.users(id),
  amount_minor integer not null check (amount_minor > 0),
  currency text not null default 'PLN' check (currency = 'PLN'),
  note text,
  paid_at date not null,
  operation_id uuid not null unique,
  reversed_at timestamptz,
  reversal_operation_id uuid unique,
  created_at timestamptz not null default now(),
  check (from_user <> to_user)
);

alter table public.user_connection enable row level security;
alter table public.connection_invitation enable row level security;
alter table public.repayment enable row level security;

create or replace function public.are_connected(p_left uuid, p_right uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_connection c
    where c.accepted_at is not null
      and ((c.user_a = p_left and c.user_b = p_right) or (c.user_a = p_right and c.user_b = p_left))
  );
$$;

create policy "connection_select_participant" on public.user_connection for select
  using (auth.uid() in (user_a, user_b));
create policy "invitation_select_creator_or_recipient" on public.connection_invitation for select
  using (auth.uid() = created_by or auth.uid() = invited_user_id);
create policy "repayment_select_counterparty" on public.repayment for select
  using (auth.uid() in (from_user, to_user));

-- A participant may see only an expense they participate in. This intentionally
-- supersedes household-wide visibility from the prototype.
drop policy if exists "expense_select_own_or_household" on public.expense;
create policy "expense_select_participant" on public.expense for select using (
  created_by = auth.uid() or exists (
    select 1 from public.expense_share s where s.expense_id = id and s.user_id = auth.uid()
  )
);
drop policy if exists "share_select_via_expense" on public.expense_share;
create policy "share_select_participant" on public.expense_share for select using (
  exists (select 1 from public.expense_share mine where mine.expense_id = expense_id and mine.user_id = auth.uid())
  or exists (select 1 from public.expense e where e.id = expense_id and e.created_by = auth.uid())
);

-- Compute only confirmed obligations. A debt exists only after both payer and
-- debtor have accepted; opposite directions are netted within each pair.
create or replace function public.balance_snapshot()
returns table(person_id uuid, display_name text, amount_minor integer)
language sql stable security definer set search_path = public as $$
  with obligations as (
    select case when e.paid_by = auth.uid() then s.user_id else e.paid_by end as other_id,
           case when e.paid_by = auth.uid() then s.amount_minor else -s.amount_minor end as delta
    from public.expense e
    join public.expense_share s on s.expense_id = e.id
    join public.expense_share payer on payer.expense_id = e.id and payer.user_id = e.paid_by
    where s.user_id <> e.paid_by
      and (e.paid_by = auth.uid() or s.user_id = auth.uid())
      and s.status = 'accepted' and payer.status = 'accepted'
  ), payments as (
    select case when r.to_user = auth.uid() then r.from_user else r.to_user end as other_id,
           case when r.to_user = auth.uid() then -r.amount_minor else r.amount_minor end as delta
    from public.repayment r where auth.uid() in (r.from_user, r.to_user) and r.reversed_at is null
  ), net as (
    select other_id, sum(delta)::integer as amount_minor from (select * from obligations union all select * from payments) x group by other_id
  )
  select n.other_id, coalesce(p.display_name, 'Connected person'), n.amount_minor
  from net n join public.profile p on p.id = n.other_id where n.amount_minor <> 0;
$$;

create or replace function public.create_repayment(p_to_user_id uuid, p_amount_minor integer, p_note text, p_paid_at date, p_operation_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_debt integer;
begin
  if auth.uid() is null or p_amount_minor <= 0 or p_to_user_id = auth.uid() then raise exception 'Invalid repayment'; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_to_user_id::text, 0));
  select -amount_minor into v_debt from public.balance_snapshot() where person_id = p_to_user_id;
  if coalesce(v_debt, 0) < p_amount_minor then raise exception 'Repayment exceeds confirmed debt'; end if;
  insert into public.repayment(from_user, to_user, amount_minor, note, paid_at, operation_id)
  values (auth.uid(), p_to_user_id, p_amount_minor, p_note, p_paid_at, p_operation_id)
  on conflict (operation_id) do update set operation_id = excluded.operation_id returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.reverse_repayment(p_repayment_id uuid, p_operation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update public.repayment set reversed_at = now(), reversal_operation_id = p_operation_id
  where id = p_repayment_id and from_user = auth.uid() and reversed_at is null;
  if not found then raise exception 'Repayment not found or already reversed'; end if;
end;
$$;

create or replace function public.balance_history(p_person_id uuid)
returns table(id uuid, kind text, title text, amount_minor integer, occurred_at timestamptz, status public.expense_share_status)
language sql stable security definer set search_path = public as $$
  select e.id, 'purchase', coalesce(e.title, e.category::text),
         case when e.paid_by = auth.uid() then s.amount_minor else -s.amount_minor end,
         e.spent_at::timestamptz, s.status
  from public.expense e join public.expense_share s on s.expense_id = e.id
  where ((e.paid_by = auth.uid() and s.user_id = p_person_id) or (e.paid_by = p_person_id and s.user_id = auth.uid()))
  union all
  select r.id, case when r.reversed_at is null then 'repayment' else 'reversal' end,
         coalesce(r.note, 'Repayment'), case when r.to_user = auth.uid() then -r.amount_minor else r.amount_minor end,
         r.paid_at::timestamptz, null
  from public.repayment r where (r.from_user = auth.uid() and r.to_user = p_person_id) or (r.to_user = auth.uid() and r.from_user = p_person_id)
  order by 5 desc;
$$;

grant execute on function public.balance_snapshot(), public.balance_history(uuid), public.create_repayment(uuid, integer, text, date, uuid), public.reverse_repayment(uuid, uuid) to authenticated;
