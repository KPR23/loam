-- Someone who is owed money can record that the other person paid them. The
-- repayment row is the same as one the payer would record, so balances and
-- history need no changes; only the activity event differs, because the actor
-- is the receiver and each side must read it from their own point of view.
do $$ declare c record; begin
  for c in select conname from pg_constraint
    where conrelid='public.activity_event'::regclass and contype='c' and pg_get_constraintdef(oid) like '%kind%'
  loop execute format('alter table public.activity_event drop constraint %I',c.conname); end loop;
end $$;
alter table public.activity_event add constraint activity_event_kind_check check (kind in (
  'shared','accepted','rejected','edited','participant_removed','deleted','proposal_created','proposal_accepted',
  'proposal_rejected','auto_accepted','proposal_superseded','repayment_recorded','repayment_reversed','repayment_received'));

create or replace function private.notification_category(p_kind text) returns text
language sql immutable set search_path='' as $$
  select case p_kind
    when 'shared' then 'requests' when 'proposal_created' then 'requests'
    when 'accepted' then 'replies' when 'rejected' then 'replies' when 'proposal_accepted' then 'replies'
      when 'proposal_rejected' then 'replies' when 'auto_accepted' then 'replies'
    when 'repayment_recorded' then 'repayments' when 'repayment_reversed' then 'repayments'
      when 'repayment_received' then 'repayments'
    else 'changes' end
$$;

create or replace function private.log_repayment_activity() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_kind text; v_actor uuid;
begin
  v_actor:=coalesce(auth.uid(),new.from_user);
  if tg_op='INSERT' then v_kind:=case when v_actor=new.to_user then 'repayment_received' else 'repayment_recorded' end;
  elsif old.reversed_at is null and new.reversed_at is not null then v_kind:='repayment_reversed';
  else return new; end if;
  insert into public.activity_event(audience_user_id,kind,actor_id,recipient_id,recipient_ids,repayment_id,
    expense_title,category,affected_share_minor,expense_total_minor,currency)
  select u,v_kind,v_actor,case when v_actor=new.from_user then new.to_user else new.from_user end,
    array[case when v_actor=new.from_user then new.to_user else new.from_user end],new.id,
    coalesce(nullif(btrim(new.note),''),'Repayment'),'other',new.amount_minor,new.amount_minor,new.currency
  from unnest(array[new.from_user,new.to_user]) u;
  return new;
end $$;

create function public.create_received_repayment(p_from_user_id uuid, p_amount_minor integer, p_currency text, p_note text, p_paid_at date, p_operation_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_owed bigint;
begin
  if not public.current_account_is_active() or p_amount_minor <= 0 or p_from_user_id = auth.uid() or p_currency not in ('PLN','EUR','USD') then raise exception 'Invalid repayment'; end if;
  select id into v_id from public.repayment where operation_id = p_operation_id and to_user = auth.uid(); if v_id is not null then return v_id; end if;
  -- The key create_repayment takes for this payer and receiver, so both sides recording at once can't overpay.
  perform pg_advisory_xact_lock(hashtextextended(p_from_user_id::text || auth.uid()::text || p_currency, 0));
  if not public.current_account_is_active() then raise exception 'Account is closed'; end if;
  select amount_minor into v_owed from public.balance_snapshot() where person_id = p_from_user_id and currency = p_currency;
  if coalesce(v_owed, 0) < p_amount_minor then raise exception 'Repayment exceeds confirmed debt'; end if;
  insert into public.repayment(from_user, to_user, amount_minor, currency, note, paid_at, operation_id) values (p_from_user_id, auth.uid(), p_amount_minor, p_currency, p_note, p_paid_at, p_operation_id) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.create_received_repayment(uuid,integer,text,text,date,uuid) from public, anon;
grant execute on function public.create_received_repayment(uuid,integer,text,text,date,uuid) to authenticated;

notify pgrst,'reload schema';
