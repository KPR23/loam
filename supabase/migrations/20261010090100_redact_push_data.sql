-- Account deletion soft-deletes auth.users, so on-delete cascades never fire. Clear the push tables here.
create or replace function public.redact_account_data(p_user_id uuid) returns void
language plpgsql set search_path='' as $$
begin
  if p_user_id is null then raise exception 'User ID is required'; end if;
  -- Activity resolves names from the profile, so this also redacts history.
  update public.profile set display_name='Deleted user',avatar_path=null,deleted_at=now() where id=p_user_id;
  if not found then raise exception 'Profile not found for account deletion'; end if;

  -- Private expenses are visible only to this account. Shared transactions,
  -- shares and repayments remain intact for the other participants.
  delete from public.expense
  where created_by=p_user_id and not exists(select 1 from public.expense_share s where s.expense_id=expense.id and s.user_id<>p_user_id);
  update public.recurring_rule r set is_active=false,version=version+1
  where owner_user_id<>p_user_id and exists(select 1 from jsonb_array_elements(r.shares) s where (s->>'user_id')::uuid=p_user_id);
  delete from public.recurring_rule where owner_user_id=p_user_id;
  delete from public.activity_event where audience_user_id=p_user_id;
  -- Push tokens and notification choices belong to the live account only.
  delete from private.push_device where user_id=p_user_id;
  delete from private.notification_preference where user_id=p_user_id;
  delete from public.connection_invitation where created_by=p_user_id or invited_user_id=p_user_id;
  delete from public.expense_share_trust where user_id=p_user_id or trusted_user_id=p_user_id;
  delete from public.user_connection where user_a=p_user_id or user_b=p_user_id;
end $$;

notify pgrst,'reload schema';
