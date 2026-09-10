-- Ensure each participant accepts/rejects only their own share, independently.
-- Other participants' pending shares must remain pending after one person responds.

drop policy if exists "share_update_via_expense" on public.expense_share;
drop policy if exists "share_update_own_acceptance" on public.expense_share;

-- Creator may rewrite shares (e.g. via update_expense_with_shares RPC).
create policy "share_update_creator"
  on public.expense_share for update
  using (
    exists (
      select 1 from public.expense e
      where e.id = expense_id
        and e.created_by = auth.uid()
    )
  )
  with check (
    exists (
      select 1 from public.expense e
      where e.id = expense_id
        and e.created_by = auth.uid()
    )
  );

-- Each participant may update only their own share row (accept / reject).
create policy "share_update_own_status"
  on public.expense_share for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create or replace function public.respond_to_expense_share(
  p_expense_id uuid,
  p_action text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_share_id uuid;
  v_share_status public.expense_share_status;
  v_household_id uuid;
  v_created_by uuid;
  v_updated integer;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if p_action not in ('accept', 'reject', 'accept_with_trust') then
    raise exception 'Invalid action';
  end if;

  select e.household_id, e.created_by
  into v_household_id, v_created_by
  from public.expense e
  where e.id = p_expense_id;

  if v_household_id is null then
    raise exception 'Not a shared expense';
  end if;

  if not public.is_household_member(v_household_id) then
    raise exception 'Not a household member';
  end if;

  -- Lock only this participant's share row — never touch other participants.
  select s.id, s.status
  into v_share_id, v_share_status
  from public.expense_share s
  where s.expense_id = p_expense_id
    and s.user_id = v_user_id
  for update;

  if v_share_id is null then
    raise exception 'Share not found';
  end if;

  if v_share_status <> 'pending' then
    raise exception 'Share is not pending';
  end if;

  if p_action = 'reject' then
    update public.expense_share
    set status = 'rejected',
        responded_at = now(),
        accepted_via_trust = false
    where id = v_share_id
      and user_id = v_user_id
      and status = 'pending';
  else
    update public.expense_share
    set status = 'accepted',
        responded_at = now(),
        accepted_via_trust = false
    where id = v_share_id
      and user_id = v_user_id
      and status = 'pending';
  end if;

  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    raise exception 'Failed to update own share';
  end if;

  -- Trust is also per-user: only the responding participant opts in.
  if p_action = 'accept_with_trust' then
    insert into public.expense_share_trust (household_id, user_id, trusted_user_id)
    values (v_household_id, v_user_id, v_created_by)
    on conflict (household_id, user_id, trusted_user_id) do nothing;
  end if;
end;
$$;

revoke all on function public.respond_to_expense_share(uuid, text) from public;
grant execute on function public.respond_to_expense_share(uuid, text) to authenticated;

notify pgrst, 'reload schema';
