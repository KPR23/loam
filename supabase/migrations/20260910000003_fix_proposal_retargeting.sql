-- Prevent proposers from retargeting a pending proposal onto an expense they
-- do not participate in, and re-check participation when accepting.

drop policy if exists "proposal_update_creator" on public.expense_edit_proposal;

create policy "proposal_update_participant_or_creator"
  on public.expense_edit_proposal for update
  using (
    exists (
      select 1 from public.expense e
      where e.id = expense_id and e.created_by = auth.uid()
    )
    or proposed_by = auth.uid()
  )
  with check (
    (
      exists (
        select 1 from public.expense e
        where e.id = expense_id and e.created_by = auth.uid()
      )
    )
    or (
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
    )
  );

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

  -- Reject retargeted proposals where the proposer is not on this expense.
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
