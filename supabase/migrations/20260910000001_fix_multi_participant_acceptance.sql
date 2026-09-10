-- Fix share acceptance for multi-participant expenses: run RPC as definer so
-- participant updates are not blocked by overlapping RLS policies.

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

  if v_expense.household_id is null then
    raise exception 'Not a shared expense';
  end if;

  if not public.is_household_member(v_expense.household_id) then
    raise exception 'Not a household member';
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
    where id = v_share.id
      and user_id = v_user_id;
    return;
  end if;

  update public.expense_share
  set status = 'accepted', responded_at = now(), accepted_via_trust = false
  where id = v_share.id
    and user_id = v_user_id;

  if p_action = 'accept_with_trust' then
    insert into public.expense_share_trust (household_id, user_id, trusted_user_id)
    values (v_expense.household_id, v_user_id, v_expense.created_by)
    on conflict (household_id, user_id, trusted_user_id) do nothing;
  end if;
end;
$$;

revoke all on function public.respond_to_expense_share(uuid, text) from public;
grant execute on function public.respond_to_expense_share(uuid, text) to authenticated;

notify pgrst, 'reload schema';
