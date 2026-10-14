-- People without an account belong to the account that added them, so deleting that
-- account deletes them too. Account deletion only soft-deletes the auth user, which never
-- fires the profile.managed_by cascade, so until now their names, and every expense and
-- repayment that only involved them and the deleted account, stayed in the database.
--
-- Removed placeholders are included: removing one keeps its name for the owner's history.
-- A placeholder's share in an expense with another real friend stays, under "Deleted user",
-- so that friend's balance remains correct. Safe to run twice: deletion redacts again when
-- the auth user is soft-deleted.

create or replace function public.redact_account_data(p_user_id uuid) returns void
language plpgsql set search_path='' as $$
declare v_placeholders uuid[];
begin
  if p_user_id is null then raise exception 'User ID is required'; end if;
  -- Activity resolves names from the profile, so this also redacts history.
  update public.profile set display_name='Deleted user',avatar_path=null,deleted_at=now() where id=p_user_id;
  if not found then raise exception 'Profile not found for account deletion'; end if;

  select coalesce(array_agg(p.id),'{}') into v_placeholders from public.profile p where p.managed_by=p_user_id;
  update public.profile set display_name='Deleted user',avatar_path=null,deleted_at=coalesce(deleted_at,now())
  where id=any(v_placeholders);
  -- The signup trigger copied the name from here.
  update auth.users set raw_user_meta_data='{}'::jsonb where id=any(v_placeholders);

  -- Private expenses are visible only to this account, and so are expenses shared only
  -- with its placeholders. Shared transactions, shares and repayments remain intact for
  -- the other participants.
  delete from public.expense
  where created_by=p_user_id and not exists(select 1 from public.expense_share s
    where s.expense_id=expense.id and s.user_id<>p_user_id and not s.user_id=any(v_placeholders));
  delete from public.repayment
  where (from_user=p_user_id and to_user=any(v_placeholders)) or (to_user=p_user_id and from_user=any(v_placeholders));
  update public.recurring_rule r set is_active=false,version=version+1
  where owner_user_id<>p_user_id and exists(select 1 from jsonb_array_elements(r.shares) s where (s->>'user_id')::uuid=p_user_id);
  delete from public.recurring_rule where owner_user_id=p_user_id;
  delete from public.activity_event where audience_user_id=p_user_id or audience_user_id=any(v_placeholders);
  delete from public.connection_invitation where created_by=p_user_id or invited_user_id=p_user_id;
  delete from public.expense_share_trust where user_id=p_user_id or trusted_user_id=p_user_id;
  delete from public.user_connection where user_a=p_user_id or user_b=p_user_id or user_a=any(v_placeholders) or user_b=any(v_placeholders);
end $$;

notify pgrst,'reload schema';
