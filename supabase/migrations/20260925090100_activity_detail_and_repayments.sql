-- Activity feed fixes from manual testing:
-- * Applying a suggested edit logged both "accepted a participant's proposal"
--   and "edited a shared expense" for the owner and proposer. The proposal
--   event now names the proposer, and the plain edit event only goes to the
--   other participants, who get no proposal event.
-- * The feed returns recipient IDs, so the app can say "you" instead of the
--   viewer's own name in every sentence.
-- * Recording or reversing a repayment is now recorded for both people.
-- * expense_activity() returns one expense's history for its detail screen.

do $$ declare c record; begin
  for c in select conname from pg_constraint
    where conrelid='public.activity_event'::regclass and contype='c' and pg_get_constraintdef(oid) like '%kind%'
  loop execute format('alter table public.activity_event drop constraint %I',c.conname); end loop;
end $$;
alter table public.activity_event add constraint activity_event_kind_check check (kind in (
  'shared','accepted','rejected','edited','participant_removed','deleted','proposal_created','proposal_accepted',
  'proposal_rejected','auto_accepted','proposal_superseded','repayment_recorded','repayment_reversed'));
alter table public.activity_event add column repayment_id uuid;
create index activity_event_audience_expense_idx on public.activity_event(audience_user_id,expense_id,occurred_at desc);

-- An explicit recipient lets proposal responses name the proposer instead of
-- the expense owner, who is also the actor.
drop function private.log_expense_event(text,public.expense,jsonb,uuid,uuid[]);
create function private.log_expense_event(p_kind text,p_expense public.expense,p_shares jsonb,p_actor uuid,
  p_audience uuid[] default null,p_recipient uuid default null)
returns void language plpgsql set search_path='' as $$
begin
  if jsonb_array_length(p_shares)<2 then return; end if;
  insert into public.activity_event(audience_user_id,kind,actor_id,recipient_id,recipient_ids,
    expense_id,expense_title,category,affected_share_minor,expense_total_minor,currency)
  select (s->>'user_id')::uuid,p_kind,p_actor,
    coalesce(p_recipient,case when p_actor<>p_expense.created_by then p_expense.created_by end),
    array(select (x->>'user_id')::uuid from jsonb_array_elements(p_shares) x where (x->>'user_id')::uuid<>p_actor),
    p_expense.id,coalesce(nullif(p_expense.title,''),initcap(p_expense.category::text)),p_expense.category,
    (s->>'amount_minor')::integer,p_expense.amount_minor,p_expense.currency
  from jsonb_array_elements(p_shares) s where p_audience is null or (s->>'user_id')::uuid=any(p_audience);
end $$;
revoke all on function private.log_expense_event(text,public.expense,jsonb,uuid,uuid[],uuid) from public,anon,authenticated;

-- Unchanged from 20260924190000 except for the edit event after a proposal.
create or replace function private.save_expense_as(p_uid uuid,p_expense jsonb,p_expected_version bigint,p_accepted_user uuid default null)
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
  if p_accepted_user is null then
    perform private.log_expense_event(case when old_e.id is null then 'shared' else 'edited' end,e,private.expense_shares(v_id),p_uid);
  else
    -- The owner and proposer get the proposal_accepted event instead.
    perform private.log_expense_event('edited',e,private.expense_shares(v_id),p_uid,
      array(select user_id from public.expense_share where expense_id=v_id and user_id<>p_uid and user_id<>p_accepted_user));
  end if;
  if old_e.id is not null then
    perform private.log_expense_event('participant_removed',old_e,old_shares,p_uid,
      array(select (x->>'user_id')::uuid from jsonb_array_elements(old_shares) x where not exists(
        select 1 from public.expense_share where expense_id=v_id and user_id=(x->>'user_id')::uuid)));
  end if;
  return v_id;
end $$;
revoke all on function private.save_expense_as(uuid,jsonb,bigint,uuid) from public,anon,authenticated;

-- Unchanged from 20260924190000 except that the event names the proposer.
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
  perform private.log_expense_event(case when p_accept then 'proposal_accepted' else 'proposal_rejected' end,e,private.expense_shares(e.id),auth.uid(),
    array[p.proposed_by,e.created_by],p.proposed_by);
end $$;

-- Repayments are written by create_repayment/reverse_repayment; triggers keep
-- those functions unchanged. Only the two people involved see the event.
create function private.log_repayment_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_kind text; v_actor uuid;
begin
  if tg_op='INSERT' then v_kind:='repayment_recorded';
  elsif old.reversed_at is null and new.reversed_at is not null then v_kind:='repayment_reversed';
  else return new; end if;
  v_actor:=coalesce(auth.uid(),new.from_user);
  insert into public.activity_event(audience_user_id,kind,actor_id,recipient_id,recipient_ids,repayment_id,
    expense_title,category,affected_share_minor,expense_total_minor,currency)
  select u,v_kind,v_actor,case when v_actor=new.from_user then new.to_user else new.from_user end,
    array[case when v_actor=new.from_user then new.to_user else new.from_user end],new.id,
    coalesce(nullif(btrim(new.note),''),'Repayment'),'other',new.amount_minor,new.amount_minor,new.currency
  from unnest(array[new.from_user,new.to_user]) u;
  return new;
end $$;
revoke all on function private.log_repayment_activity() from public,anon,authenticated;
create trigger activity_repayment_recorded after insert on public.repayment
  for each row execute function private.log_repayment_activity();
create trigger activity_repayment_reversed after update of reversed_at on public.repayment
  for each row execute function private.log_repayment_activity();

drop function public.activity_page(uuid);
create function public.activity_page(p_before_id uuid default null)
returns table(id uuid,audience_user_id uuid,occurred_at timestamptz,kind text,actor_id uuid,actor_name text,
  recipient_id uuid,recipient_name text,recipient_names text[],recipient_ids uuid[],expense_id uuid,repayment_id uuid,expense_title text,
  category public.expense_category,affected_share_minor integer,expense_total_minor integer,currency text)
language sql stable security definer set search_path='' as $$
  select a.id,a.audience_user_id,a.occurred_at,a.kind,a.actor_id,public.activity_name(a.actor_id),
    a.recipient_id,case when a.recipient_id is not null then public.activity_name(a.recipient_id) end,
    array(select public.activity_name(r.id) from unnest(a.recipient_ids) with ordinality r(id,n) order by r.n),
    a.recipient_ids,a.expense_id,a.repayment_id,a.expense_title,a.category,a.affected_share_minor,a.expense_total_minor,a.currency
  from public.activity_event a
  where public.current_account_is_active() and a.audience_user_id=auth.uid()
    and (p_before_id is null or (a.occurred_at,a.id)<
      (select b.occurred_at,b.id from public.activity_event b where b.id=p_before_id and b.audience_user_id=auth.uid()))
  order by a.occurred_at desc,a.id desc limit 51
$$;
revoke all on function public.activity_page(uuid) from public,anon,authenticated;
grant execute on function public.activity_page(uuid) to authenticated;

-- The newest 200 events of one expense's history as the caller saw it,
-- returned oldest first.
create function public.expense_activity(p_expense_id uuid)
returns table(id uuid,audience_user_id uuid,occurred_at timestamptz,kind text,actor_id uuid,actor_name text,
  recipient_id uuid,recipient_name text,recipient_names text[],recipient_ids uuid[],expense_id uuid,repayment_id uuid,expense_title text,
  category public.expense_category,affected_share_minor integer,expense_total_minor integer,currency text)
language sql stable security definer set search_path='' as $$
  select a.id,a.audience_user_id,a.occurred_at,a.kind,a.actor_id,public.activity_name(a.actor_id),
    a.recipient_id,case when a.recipient_id is not null then public.activity_name(a.recipient_id) end,
    array(select public.activity_name(r.id) from unnest(a.recipient_ids) with ordinality r(id,n) order by r.n),
    a.recipient_ids,a.expense_id,a.repayment_id,a.expense_title,a.category,a.affected_share_minor,a.expense_total_minor,a.currency
  from (select * from public.activity_event e
    where public.current_account_is_active() and e.audience_user_id=auth.uid() and e.expense_id=p_expense_id
    order by e.occurred_at desc,e.id desc limit 200) a
  order by a.occurred_at,a.id
$$;
revoke all on function public.expense_activity(uuid) from public,anon,authenticated;
grant execute on function public.expense_activity(uuid) to authenticated;

notify pgrst,'reload schema';
