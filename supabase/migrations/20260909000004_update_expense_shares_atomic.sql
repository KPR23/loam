-- Replace expense shares atomically so the deferred sum trigger only runs at commit.

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
    insert into public.expense_share (expense_id, user_id, amount_minor)
    values (
      p_expense_id,
      (v_share->>'user_id')::uuid,
      (v_share->>'amount_minor')::integer
    );
  end loop;
end;
$$;

revoke all on function public.update_expense_with_shares(
  uuid, integer, text, public.expense_category, text, date, uuid, uuid, uuid, jsonb
) from public;

grant execute on function public.update_expense_with_shares(
  uuid, integer, text, public.expense_category, text, date, uuid, uuid, uuid, jsonb
) to authenticated;

notify pgrst, 'reload schema';
