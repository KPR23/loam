-- Follow-up hardening for the balances rollout. This migration is intentionally
-- self-contained so it repairs installations that applied the initial balances
-- migration before the policy and idempotency issues were discovered.

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

-- SECURITY DEFINER avoids a circular expense <-> expense_share RLS evaluation.
-- The function exposes no rows and is executable only by authenticated users.
create or replace function private.can_read_expense_shares(p_expense_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and (
      exists (
        select 1 from public.expense e
        where e.id = p_expense_id and e.created_by = (select auth.uid())
      )
      or exists (
        select 1 from public.expense_share mine
        where mine.expense_id = p_expense_id and mine.user_id = (select auth.uid())
      )
    );
$$;

revoke all on function private.can_read_expense_shares(uuid) from public;
grant execute on function private.can_read_expense_shares(uuid) to authenticated;

drop policy if exists "expense_select_participant" on public.expense;
create policy "expense_select_participant"
  on public.expense
  for select
  to authenticated
  using (
    created_by = (select auth.uid())
    or exists (
      select 1 from public.expense_share s
      where s.expense_id = expense.id and s.user_id = (select auth.uid())
    )
  );

drop policy if exists "share_select_via_expense" on public.expense_share;
drop policy if exists "share_select_participant" on public.expense_share;
create policy "share_select_participant"
  on public.expense_share
  for select
  to authenticated
  using (private.can_read_expense_shares(expense_id));

-- Connections are private: callers may check only a pair they are part of.
create or replace function public.are_connected(p_left uuid, p_right uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select (select auth.uid()) is not null
    and (select auth.uid()) in (p_left, p_right)
    and exists (
      select 1 from public.user_connection c
      where c.accepted_at is not null
        and ((c.user_a = p_left and c.user_b = p_right) or (c.user_a = p_right and c.user_b = p_left))
    );
$$;

-- Idempotency must be checked before calculating the live debt. Otherwise a
-- response-lost retry looks like an overpayment after its first write succeeds.
create or replace function public.create_repayment(p_to_user_id uuid, p_amount_minor integer, p_note text, p_paid_at date, p_operation_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_debt integer;
begin
  if auth.uid() is null or p_amount_minor <= 0 or p_to_user_id = auth.uid() then
    raise exception 'Invalid repayment';
  end if;

  select id into v_id from public.repayment
  where operation_id = p_operation_id and from_user = auth.uid();
  if v_id is not null then return v_id; end if;

  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_to_user_id::text, 0));
  select id into v_id from public.repayment
  where operation_id = p_operation_id and from_user = auth.uid();
  if v_id is not null then return v_id; end if;

  select -amount_minor into v_debt from public.balance_snapshot() where person_id = p_to_user_id;
  if coalesce(v_debt, 0) < p_amount_minor then
    raise exception 'Repayment exceeds confirmed debt';
  end if;

  insert into public.repayment(from_user, to_user, amount_minor, note, paid_at, operation_id)
  values (auth.uid(), p_to_user_id, p_amount_minor, p_note, p_paid_at, p_operation_id)
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.reverse_repayment(p_repayment_id uuid, p_operation_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_repayment_id::text, 1));

  if exists (
    select 1 from public.repayment
    where id = p_repayment_id and from_user = auth.uid()
      and reversal_operation_id = p_operation_id
  ) then return; end if;

  update public.repayment
  set reversed_at = now(), reversal_operation_id = p_operation_id
  where id = p_repayment_id and from_user = auth.uid() and reversed_at is null;
  if not found then raise exception 'Repayment not found or already reversed'; end if;
end;
$$;

revoke all on function public.are_connected(uuid, uuid), public.balance_snapshot(), public.balance_history(uuid), public.create_repayment(uuid, integer, text, date, uuid), public.reverse_repayment(uuid, uuid) from public;
grant execute on function public.are_connected(uuid, uuid), public.balance_snapshot(), public.balance_history(uuid), public.create_repayment(uuid, integer, text, date, uuid), public.reverse_repayment(uuid, uuid) to authenticated;
