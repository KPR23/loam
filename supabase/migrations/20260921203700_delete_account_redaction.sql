-- Keep the user UUID as a tombstone for shared expenses and balances while
-- removing account-owned private data before Supabase Auth soft-deletes it.
alter table public.profile add column if not exists deleted_at timestamptz;

create or replace function public.redact_account_data(p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_names text[];
begin
  if p_user_id is null then
    raise exception 'User ID is required';
  end if;

  -- Activity keeps display-name snapshots. Collect previous names before
  -- replacing them, including names changed since an event was recorded.
  select coalesce(array_agg(distinct name), '{}'::text[])
  into v_names
  from (
    select display_name as name from public.profile where id = p_user_id
    union all
    select display_name from public.household_member where user_id = p_user_id
    union all
    select actor_name from public.activity_event where actor_id = p_user_id
    union all
    select recipient_name from public.activity_event where recipient_id = p_user_id
  ) names
  where name is not null and name <> 'Deleted user';

  update public.profile
  set display_name = 'Deleted user', avatar_path = null, deleted_at = now()
  where id = p_user_id;
  if not found then
    raise exception 'Profile not found for account deletion';
  end if;

  update public.household_member
  set display_name = 'Deleted user'
  where user_id = p_user_id;

  update public.activity_event
  set actor_name = case when actor_id = p_user_id then 'Deleted user' else actor_name end,
      recipient_name = case when recipient_id = p_user_id then 'Deleted user' else recipient_name end,
      recipient_names = case when recipient_names && v_names then '{}'::text[] else recipient_names end
  where actor_id = p_user_id
     or recipient_id = p_user_id
     or recipient_names && v_names;

  -- Private expenses are visible only to this account. Shared transactions,
  -- shares and repayments remain intact for the other participants.
  delete from public.expense
  where created_by = p_user_id and household_id is null;
  delete from public.recurring_rule where owner_user_id = p_user_id;
  delete from public.activity_event where audience_user_id = p_user_id;
  delete from public.connection_invitation
  where created_by = p_user_id or invited_user_id = p_user_id;
  delete from public.expense_share_trust
  where user_id = p_user_id or trusted_user_id = p_user_id;
  delete from public.user_connection
  where user_a = p_user_id or user_b = p_user_id;
end;
$$;

revoke all on function public.redact_account_data(uuid) from public, anon, authenticated;
grant execute on function public.redact_account_data(uuid) to service_role;

-- An accepted connection is no longer usable once either account is deleted.
create or replace function public.are_connected(p_left uuid, p_right uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and (select auth.uid()) in (p_left, p_right)
    and exists (
      select 1 from public.profile p
      where p.id = p_left and p.deleted_at is null
    )
    and exists (
      select 1 from public.profile p
      where p.id = p_right and p.deleted_at is null
    )
    and exists (
      select 1 from public.user_connection c
      where c.accepted_at is not null
        and ((c.user_a = p_left and c.user_b = p_right)
          or (c.user_a = p_right and c.user_b = p_left))
    );
$$;

revoke all on function public.are_connected(uuid, uuid) from public;
grant execute on function public.are_connected(uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
