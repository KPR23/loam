-- Editing an expense used to delete and re-insert every share, so fixing a
-- typo sent accepted debts back to pending (and could flip balances after a
-- repayment). A participant's response now survives an edit when their own
-- amount, the payer and the currency are unchanged. The body moves to a
-- private function so proposal acceptance and recurring generation can save
-- on the creator's behalf.
create function private.save_expense_as(p_uid uuid,p_expense jsonb,p_expected_version bigint,p_accepted_user uuid default null)
returns uuid language plpgsql set search_path='' as $$
declare e public.expense; old_e public.expense; old_shares jsonb; s jsonb; v_id uuid:=(p_expense->>'id')::uuid;
  v_status public.expense_share_status; v_trust boolean; v_forced boolean; v_keep boolean;
  v_recurring uuid:=(p_expense->>'recurring_id')::uuid; v_user uuid;
begin
  if v_id is null then raise exception 'Expense ID is required'; end if;
  -- Serialize creation retries for an ID, then lock the actual row for edits.
  perform pg_advisory_xact_lock(hashtextextended(v_id::text,5));
  select * into old_e from public.expense where id=v_id for update;
  if found then
    if old_e.created_by<>p_uid then raise exception 'Expense not found'; end if;
    if p_expected_version is null or p_expected_version<>old_e.version then raise exception 'Expense changed. Refresh and try again.'; end if;
  elsif p_expected_version is not null then raise exception 'Expense not found'; end if;
  perform private.validate_expense_payload(p_uid,(p_expense->>'paid_by')::uuid,(p_expense->>'amount_minor')::integer,p_expense->>'currency',p_expense->'shares');
  if v_recurring is not null and not exists(select 1 from public.recurring_rule where id=v_recurring and owner_user_id=p_uid)
    then raise exception 'Recurring rule not found'; end if;
  if p_expense->>'spent_at' is null then raise exception 'Date is required'; end if;
  old_shares:=private.expense_shares(v_id);
  v_keep:=old_e.id is not null and old_e.paid_by=(p_expense->>'paid_by')::uuid and old_e.currency=p_expense->>'currency';
  insert into public.expense(id,amount_minor,currency,category,title,note,location,spent_at,paid_by,created_by,recurring_id)
  values(v_id,(p_expense->>'amount_minor')::integer,p_expense->>'currency',(p_expense->>'category')::public.expense_category,
    p_expense->>'title',p_expense->>'note',nullif(p_expense->'location','null'::jsonb),(p_expense->>'spent_at')::date,(p_expense->>'paid_by')::uuid,p_uid,v_recurring)
  on conflict(id) do update set amount_minor=excluded.amount_minor,currency=excluded.currency,category=excluded.category,title=excluded.title,
    note=excluded.note,location=excluded.location,spent_at=excluded.spent_at,paid_by=excluded.paid_by,recurring_id=excluded.recurring_id,
    version=public.expense.version+1,updated_at=now() returning * into e;
  delete from public.expense_share where expense_id=v_id and user_id not in
    (select (x->>'user_id')::uuid from jsonb_array_elements(p_expense->'shares') x);
  for s in select * from jsonb_array_elements(p_expense->'shares') loop
    v_user:=(s->>'user_id')::uuid;
    v_forced:=v_user=p_uid or v_user is not distinct from p_accepted_user;
    v_trust:=not v_forced and exists(select 1 from public.expense_share_trust where user_id=v_user and trusted_user_id=p_uid);
    v_status:=case when v_forced or v_trust then 'accepted'::public.expense_share_status else 'pending'::public.expense_share_status end;
    -- An unchanged obligation keeps the participant's own answer, including a
    -- rejection; trust only applies to new or changed amounts.
    insert into public.expense_share as cur(expense_id,user_id,amount_minor,status,responded_at,accepted_via_trust)
      values(v_id,v_user,(s->>'amount_minor')::integer,v_status,case when v_status='accepted' then now() end,v_trust)
    on conflict(expense_id,user_id) do update set amount_minor=excluded.amount_minor,
      status=case when not v_forced and v_keep and cur.amount_minor=excluded.amount_minor then cur.status else excluded.status end,
      responded_at=case when not v_forced and v_keep and cur.amount_minor=excluded.amount_minor then cur.responded_at else excluded.responded_at end,
      accepted_via_trust=case when not v_forced and v_keep and cur.amount_minor=excluded.amount_minor then cur.accepted_via_trust else excluded.accepted_via_trust end;
  end loop;
  perform private.assert_expense_integrity(v_id);
  update public.expense_edit_proposal set status='withdrawn',responded_at=now() where expense_id=v_id and status='pending';
  perform private.log_expense_event(case when old_e.id is null then 'shared' else 'edited' end,e,private.expense_shares(v_id),p_uid);
  if old_e.id is not null then
    perform private.log_expense_event('participant_removed',old_e,old_shares,p_uid,
      array(select (x->>'user_id')::uuid from jsonb_array_elements(old_shares) x where not exists(
        select 1 from public.expense_share where expense_id=v_id and user_id=(x->>'user_id')::uuid)));
  end if;
  return v_id;
end $$;

create or replace function public.save_expense(p_expense jsonb,p_expected_version bigint default null) returns uuid
language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  return private.save_expense_as(auth.uid(),p_expense,p_expected_version);
end $$;

-- Applying a proposal no longer asks the proposer to accept their own change.
create or replace function public.respond_to_edit_proposal(p_proposal_id uuid,p_accept boolean) returns void
language plpgsql security definer set search_path='' as $$
declare p public.expense_edit_proposal; e public.expense; v_expense_id uuid;
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  -- Use the same advisory-lock then row-lock order as save_expense.
  select expense_id into v_expense_id from public.expense_edit_proposal where id=p_proposal_id;
  if v_expense_id is null then raise exception 'Proposal not found'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_expense_id::text,5));
  select e0.* into e from public.expense e0 join public.expense_edit_proposal p0 on p0.expense_id=e0.id where p0.id=p_proposal_id for update of e0;
  if not found or e.created_by<>auth.uid() then raise exception 'Proposal not found'; end if;
  select * into p from public.expense_edit_proposal where id=p_proposal_id for update;
  if p.status<>'pending' or p_accept is null then raise exception 'Proposal is no longer pending'; end if;
  if p_accept then
    if p.base_version<>e.version or p.currency<>e.currency then raise exception 'Expense changed. Request a new proposal.'; end if;
    if not exists(select 1 from public.expense_share where expense_id=e.id and user_id=p.proposed_by) then raise exception 'Proposer is no longer a participant'; end if;
    perform private.save_expense_as(e.created_by,to_jsonb(p)||jsonb_build_object('id',e.id,'recurring_id',e.recurring_id),e.version,p.proposed_by);
    select * into e from public.expense where id=e.id;
  end if;
  update public.expense_edit_proposal set status=case when p_accept then 'accepted'::public.expense_proposal_status else 'rejected'::public.expense_proposal_status end,
    responded_at=now() where id=p.id;
  perform private.log_expense_event(case when p_accept then 'proposal_accepted' else 'proposal_rejected' end,e,private.expense_shares(e.id),auth.uid(),array[p.proposed_by,e.created_by]);
end $$;

-- Functions get EXECUTE for PUBLIC regardless of per-schema defaults.
revoke all on function private.save_expense_as(uuid,jsonb,bigint,uuid) from public,anon,authenticated;
