-- Avoid recursive RLS evaluation by checking membership behind a non-exposed,
-- narrowly scoped security-definer function.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated;

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
        select 1
        from public.expense e
        where e.id = p_expense_id
          and e.created_by = (select auth.uid())
      )
      or exists (
        select 1
        from public.expense_share mine
        where mine.expense_id = p_expense_id
          and mine.user_id = (select auth.uid())
      )
    );
$$;

revoke all on function private.can_read_expense_shares(uuid) from public;
grant execute on function private.can_read_expense_shares(uuid) to authenticated;

drop policy if exists "share_select_via_expense" on public.expense_share;
drop policy if exists "share_select_participant" on public.expense_share;
create policy "share_select_participant"
  on public.expense_share
  for select
  to authenticated
  using (private.can_read_expense_shares(expense_id));
