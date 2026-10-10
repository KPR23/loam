-- Either side of a connection can end it. Money still owed blocks the removal so a
-- balance can't be stranded between two people who can no longer repay each other.
-- Trust between the pair goes with the connection; expenses already shared stay as history.
create function public.remove_connection(p_user_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if p_user_id is null or p_user_id=auth.uid() then raise exception 'Friend not found'; end if;
  if exists(select 1 from public.balance_snapshot() b where b.person_id=p_user_id) then
    raise exception 'Settle up before removing this friend.';
  end if;
  delete from public.user_connection
  where user_a=least(auth.uid(),p_user_id) and user_b=greatest(auth.uid(),p_user_id);
  delete from public.expense_share_trust
  where (user_id=auth.uid() and trusted_user_id=p_user_id) or (user_id=p_user_id and trusted_user_id=auth.uid());
end $$;
revoke all on function public.remove_connection(uuid) from public,anon;
grant execute on function public.remove_connection(uuid) to authenticated;

notify pgrst, 'reload schema';
