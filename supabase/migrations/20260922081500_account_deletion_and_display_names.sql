-- Keep the profile and the names copied into each household membership in one
-- transaction. Auth metadata is updated by the client immediately afterwards.
create or replace function public.update_display_name(p_display_name text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := (select auth.uid());
  v_display_name text := nullif(btrim(p_display_name), '');
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;
  if v_display_name is null then
    raise exception 'Display name is required';
  end if;

  update public.profile
  set display_name = v_display_name
  where id = v_user_id and deleted_at is null;
  if not found then
    raise exception 'Profile not found';
  end if;

  update public.household_member
  set display_name = v_display_name
  where user_id = v_user_id;
end;
$$;

revoke all on function public.update_display_name(text) from public, anon;
grant execute on function public.update_display_name(text) to authenticated;

-- Auth soft deletion and database redaction must be all-or-nothing. The Edge
-- Function deletes Auth first; this trigger makes redaction part of that same
-- transaction, so a redaction failure rolls back the account deletion too.
create or replace function public.redact_account_on_auth_deletion()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.redact_account_data(new.id);
  return new;
end;
$$;

drop trigger if exists on_auth_user_soft_deleted on auth.users;
create trigger on_auth_user_soft_deleted
  after update of deleted_at on auth.users
  for each row
  when (old.deleted_at is null and new.deleted_at is not null)
  execute function public.redact_account_on_auth_deletion();

notify pgrst, 'reload schema';
