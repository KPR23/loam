-- Optional short title for expenses. UI falls back to category name when null/blank.

alter table public.expense
  add column if not exists title text;

alter table public.recurring_rule
  add column if not exists title text;

alter table public.expense_edit_proposal
  add column if not exists title text;

-- ---------------------------------------------------------------------------
-- create_expense_edit_proposal (+ title)
-- ---------------------------------------------------------------------------

drop function if exists public.create_expense_edit_proposal(
  uuid, integer, public.expense_category, text, date, uuid, jsonb, text
);

create or replace function public.create_expense_edit_proposal(
  p_expense_id uuid,
  p_amount_minor integer,
  p_category public.expense_category,
  p_title text,
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

  update public.expense_edit_proposal
  set status = 'withdrawn', responded_at = now()
  where expense_id = p_expense_id
    and proposed_by = v_user_id
    and status = 'pending';

  insert into public.expense_edit_proposal (
    expense_id, proposed_by, amount_minor, category, title, note,
    spent_at, paid_by, shares, message
  )
  values (
    p_expense_id, v_user_id, p_amount_minor, p_category, p_title, p_note,
    p_spent_at, p_paid_by, p_shares, p_message
  )
  returning id into v_proposal_id;

  return v_proposal_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- respond_to_edit_proposal (apply title)
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

  if v_expense.id is null or v_expense.household_id is null then
    raise exception 'Expense not found';
  end if;

  if v_expense.created_by <> v_user_id then
    raise exception 'Only creator can respond';
  end if;

  if not p_accept then
    update public.expense_edit_proposal
    set status = 'rejected', responded_at = now()
    where id = p_proposal_id;
    return;
  end if;

  if v_proposal.proposed_by = v_expense.created_by
     or not exists (
       select 1 from public.expense_share s
       where s.expense_id = v_proposal.expense_id
         and s.user_id = v_proposal.proposed_by
     )
  then
    raise exception 'Proposer is not a participant';
  end if;

  update public.expense
  set
    amount_minor = v_proposal.amount_minor,
    category = v_proposal.category,
    title = v_proposal.title,
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

  update public.expense_edit_proposal
  set status = 'rejected', responded_at = now()
  where expense_id = v_proposal.expense_id
    and id <> p_proposal_id
    and status = 'pending';
end;
$$;

-- ---------------------------------------------------------------------------
-- update_expense_with_shares (+ title)
-- ---------------------------------------------------------------------------

drop function if exists public.update_expense_with_shares(
  uuid, integer, text, public.expense_category, text, date, uuid, uuid, uuid, jsonb
);

create or replace function public.update_expense_with_shares(
  p_expense_id uuid,
  p_amount_minor integer,
  p_currency text,
  p_category public.expense_category,
  p_title text,
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

  if p_household_id is null then
    if p_paid_by <> v_user_id then
      raise exception 'Personal expenses must be paid by the creator';
    end if;

    for v_share in select * from jsonb_array_elements(p_shares)
    loop
      if (v_share->>'user_id')::uuid <> v_user_id then
        raise exception 'Personal expense shares must belong to the creator';
      end if;
    end loop;
  else
    if not public.is_household_member(p_household_id) then
      raise exception 'Not a household member';
    end if;

    if not exists (
      select 1
      from public.household_member m
      where m.household_id = p_household_id
        and m.user_id = p_paid_by
    ) then
      raise exception 'Payer must be a household member';
    end if;

    for v_share in select * from jsonb_array_elements(p_shares)
    loop
      if not exists (
        select 1
        from public.household_member m
        where m.household_id = p_household_id
          and m.user_id = (v_share->>'user_id')::uuid
      ) then
        raise exception 'Share user must be a household member';
      end if;
    end loop;
  end if;

  update public.expense
  set
    amount_minor = p_amount_minor,
    currency = p_currency,
    category = p_category,
    title = p_title,
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

revoke all on function public.update_expense_with_shares(
  uuid, integer, text, public.expense_category, text, text, date, uuid, uuid, uuid, jsonb
) from public;

grant execute on function public.update_expense_with_shares(
  uuid, integer, text, public.expense_category, text, text, date, uuid, uuid, uuid, jsonb
) to authenticated;

grant execute on function public.create_expense_edit_proposal(
  uuid, integer, public.expense_category, text, text, date, uuid, jsonb, text
) to authenticated;

grant execute on function public.respond_to_edit_proposal(uuid, boolean) to authenticated;

notify pgrst, 'reload schema';
