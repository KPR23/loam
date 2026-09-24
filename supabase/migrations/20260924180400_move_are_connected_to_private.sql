-- are_connected is only a policy helper; the app never calls it as an RPC.
-- Policies reference it by OID and follow the move. Execution stays granted
-- because RLS expressions run as the caller.
alter function public.are_connected(uuid,uuid) set schema private;

create or replace function public.respond_to_expense_share(p_expense_id uuid,p_action text) returns void
language plpgsql security definer set search_path='' as $$
declare e public.expense; v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if p_action is null or p_action not in ('accept','reject','accept_with_trust') then raise exception 'Invalid action'; end if;
  select * into e from public.expense where id=p_expense_id for update;
  if not found then raise exception 'Expense not found'; end if;
  update public.expense_share set status=case when p_action='reject' then 'rejected'::public.expense_share_status else 'accepted'::public.expense_share_status end,
    responded_at=now(),accepted_via_trust=false where expense_id=e.id and user_id=v_uid and status='pending';
  if not found then raise exception 'Pending share not found'; end if;
  if p_action='accept_with_trust' then
    if not private.are_connected(v_uid,e.created_by) then raise exception 'Connection required'; end if;
    insert into public.expense_share_trust(user_id,trusted_user_id) values(v_uid,e.created_by) on conflict(user_id,trusted_user_id) do nothing;
  end if;
  perform private.log_expense_event(case when p_action='reject' then 'rejected' else 'accepted' end,e,private.expense_shares(e.id),v_uid,array[v_uid,e.created_by]);
end $$;

notify pgrst,'reload schema';
