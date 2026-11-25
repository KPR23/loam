-- People without an account become a Loam Pro feature, and their owner can rename them.
--
-- * Adding and renaming someone needs Pro.
-- * Nothing is deleted when an account is on Free: people added before (or while subscribed)
--   stay in friends, past expenses and balances, and can still be removed. The app stops
--   offering them for new splits until the account upgrades.

create or replace function public.create_placeholder_friend(p_name text)
returns table(user_id uuid, display_name text)
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_name text:=btrim(coalesce(p_name,'')); v_id uuid:=gen_random_uuid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if not private.has_pro(v_uid) then raise exception 'People without an account need Loam Pro'; end if;
  if v_name='' or length(v_name)>100 then raise exception 'Name must be 1 to 100 characters'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text,7));
  if (select count(*) from public.profile p where p.managed_by=v_uid and p.deleted_at is null)>=20 then
    raise exception 'You can add up to 20 people without an account.';
  end if;
  -- The profile comes from the signup trigger, named from the metadata.
  insert into auth.users(id,email,aud,role,banned_until,raw_user_meta_data)
  values(v_id,'placeholder-'||v_id||'@placeholder.invalid','authenticated','authenticated','infinity',jsonb_build_object('full_name',v_name));
  update public.profile set display_name=v_name,managed_by=v_uid,auto_accept_expenses=true where id=v_id;
  insert into public.user_connection(user_a,user_b,created_by,accepted_at)
  values(least(v_uid,v_id),greatest(v_uid,v_id),v_uid,now());
  return query select v_id,v_name;
end $$;
revoke all on function public.create_placeholder_friend(text) from public,anon;
grant execute on function public.create_placeholder_friend(text) to authenticated;

-- Only the account that added the person can rename them, and only on Pro.
create function public.rename_placeholder_friend(p_user_id uuid, p_name text)
returns table(user_id uuid, display_name text)
language plpgsql security definer set search_path='' as $$
declare v_name text:=btrim(coalesce(p_name,''));
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if not private.has_pro(auth.uid()) then raise exception 'People without an account need Loam Pro'; end if;
  if v_name='' or length(v_name)>100 then raise exception 'Name must be 1 to 100 characters'; end if;
  update public.profile p set display_name=v_name
  where p.id=p_user_id and p.managed_by=auth.uid() and p.deleted_at is null;
  if not found then raise exception 'Friend not found'; end if;
  return query select p_user_id,v_name;
end $$;
revoke all on function public.rename_placeholder_friend(uuid,text) from public,anon;
grant execute on function public.rename_placeholder_friend(uuid,text) to authenticated;

notify pgrst, 'reload schema';
