-- Removing a friend used to leave expenses between the two of you that were still waiting
-- for an answer. They kept showing in Balances as waiting to be accepted, and either side
-- could still accept one later, which brought back a balance between two people who can no
-- longer settle it: exactly what refusing to remove a friend with an open balance prevents.
--
-- Removal now declines every share still pending between the pair: a share one of you owes
-- on an expense the other paid, and a payer's share on an expense the other logged for them.
-- Shares owed to a third person stay as they are. Nothing is logged in Activity, as the
-- removal itself is the event; the expenses stay in history marked as declined.

-- The shares removal would decline, so the app can say how many before asking to confirm.
create function private.pending_shares_between(p_me uuid,p_other uuid) returns setof public.expense_share
language sql stable security definer set search_path='' as $$
  select s.* from public.expense_share s join public.expense e on e.id=s.expense_id
  where s.status='pending' and e.paid_by in (p_me,p_other) and s.user_id in (p_me,p_other)
    and (s.user_id<>e.paid_by or e.created_by=case when s.user_id=p_me then p_other else p_me end)
$$;
revoke all on function private.pending_shares_between(uuid,uuid) from public,anon,authenticated;

create function public.pending_share_count(p_user_id uuid) returns integer
language sql stable security definer set search_path='' as $$
  select case when public.current_account_is_active() then
    (select count(*)::integer from private.pending_shares_between(auth.uid(),p_user_id)) else 0 end
$$;
revoke all on function public.pending_share_count(uuid) from public,anon;
grant execute on function public.pending_share_count(uuid) to authenticated;

create or replace function public.remove_connection(p_user_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if p_user_id is null or p_user_id=v_uid then raise exception 'Friend not found'; end if;
  -- Serialize removals of one person so overlapping calls can't settle the same balance twice.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,8));
  if exists(select 1 from public.profile p where p.id=p_user_id and p.managed_by=v_uid and p.deleted_at is null) then
    -- Nobody can repay for a placeholder, so removing it settles whatever is left.
    insert into public.repayment(from_user,to_user,amount_minor,currency,note,paid_at,operation_id)
    select case when b.amount_minor>0 then p_user_id else v_uid end,
           case when b.amount_minor>0 then v_uid else p_user_id end,
           abs(b.amount_minor)::integer,b.currency,'Settled when removed',current_date,gen_random_uuid()
    from public.balance_snapshot() b where b.person_id=p_user_id;
    update public.profile set deleted_at=now() where id=p_user_id;
  elsif exists(select 1 from public.balance_snapshot() b where b.person_id=p_user_id) then
    raise exception 'Settle up before removing this friend.';
  end if;
  update public.expense_share s set status='rejected',responded_at=now(),accepted_via_trust=false
  from private.pending_shares_between(v_uid,p_user_id) p
  where s.expense_id=p.expense_id and s.user_id=p.user_id;
  delete from public.user_connection
  where user_a=least(v_uid,p_user_id) and user_b=greatest(v_uid,p_user_id);
  delete from public.expense_share_trust
  where (user_id=v_uid and trusted_user_id=p_user_id) or (user_id=p_user_id and trusted_user_id=v_uid);
end $$;
revoke all on function public.remove_connection(uuid) from public,anon;
grant execute on function public.remove_connection(uuid) to authenticated;

notify pgrst,'reload schema';
