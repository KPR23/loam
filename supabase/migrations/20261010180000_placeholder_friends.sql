-- People without an account. An account can add someone by name and split expenses with
-- them like any friend, to keep track of what each of them paid.
--
-- A placeholder is a real but unusable account (no password, banned from signing in)
-- that belongs to the account that created it. That lets every existing rule keep
-- working unchanged: it is connected to its owner, appears in list_connections, can hold
-- shares and shows up in balances. It auto-accepts every expense (the migration before
-- this one), so nothing waits for an answer nobody can give.
--
-- * Placeholders don't count toward the free plan's one connection.
-- * Removing one settles its balance instead of refusing, since nobody can repay on its
--   behalf: the settlement is recorded as a repayment in Balances history.

alter table public.profile add column managed_by uuid references auth.users(id) on delete cascade;
create index profile_managed_by_idx on public.profile(managed_by) where managed_by is not null;

create function public.create_placeholder_friend(p_name text)
returns table(user_id uuid, display_name text)
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_name text:=btrim(coalesce(p_name,'')); v_id uuid:=gen_random_uuid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
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

-- Which of the caller's connections are placeholders, so the app can label them.
create function public.list_placeholder_friends() returns table(user_id uuid)
language sql stable security definer set search_path='' as $$
  select p.id from public.profile p
  where public.current_account_is_active() and p.managed_by=auth.uid() and p.deleted_at is null
$$;
revoke all on function public.list_placeholder_friends() from public,anon;
grant execute on function public.list_placeholder_friends() to authenticated;

create or replace function public.remove_connection(p_user_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if p_user_id is null or p_user_id=auth.uid() then raise exception 'Friend not found'; end if;
  -- Serialize removals of one person so overlapping calls can't settle the same balance twice.
  perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,8));
  if exists(select 1 from public.profile p where p.id=p_user_id and p.managed_by=auth.uid() and p.deleted_at is null) then
    -- Nobody can repay for a placeholder, so removing it settles whatever is left.
    insert into public.repayment(from_user,to_user,amount_minor,currency,note,paid_at,operation_id)
    select case when b.amount_minor>0 then p_user_id else auth.uid() end,
           case when b.amount_minor>0 then auth.uid() else p_user_id end,
           abs(b.amount_minor)::integer,b.currency,'Settled when removed',current_date,gen_random_uuid()
    from public.balance_snapshot() b where b.person_id=p_user_id;
    update public.profile set deleted_at=now() where id=p_user_id;
  elsif exists(select 1 from public.balance_snapshot() b where b.person_id=p_user_id) then
    raise exception 'Settle up before removing this friend.';
  end if;
  delete from public.user_connection
  where user_a=least(auth.uid(),p_user_id) and user_b=greatest(auth.uid(),p_user_id);
  delete from public.expense_share_trust
  where (user_id=auth.uid() and trusted_user_id=p_user_id) or (user_id=p_user_id and trusted_user_id=auth.uid());
end $$;

-- Same function as before, except that placeholders no longer fill the free connection.
drop function public.create_connection_invitation();
create function public.create_connection_invitation()
returns table(code text, expires_at timestamptz, error_code text)
language plpgsql security definer set search_path = '' as $$
declare v_user_id uuid := (select auth.uid()); v_code text; v_expiry timestamptz := now() + interval '24 hours';
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from public.profile p where p.id = v_user_id and p.deleted_at is null) then raise exception 'Account unavailable'; end if;
  perform 1 from public.connection_invitation as i
  where i.created_by = v_user_id and i.accepted_at is null and i.expires_at > now()
  for update;
  if not private.has_pro(v_user_id) and (
    select count(*) from public.user_connection c
    join public.profile p on p.id = case when c.user_a = v_user_id then c.user_b else c.user_a end
    where v_user_id in (c.user_a, c.user_b) and c.accepted_at is not null and p.deleted_at is null and p.managed_by is null
  ) >= 1 then
    return query select null::text, null::timestamptz, 'pro_required'::text;
    return;
  end if;
  perform public.assert_connection_code_rate('create', 10, interval '1 hour');
  update public.connection_invitation as i
  set expires_at = now()
  where i.created_by = v_user_id and i.accepted_at is null and i.expires_at > now();
  loop
    v_code := public.connection_code_value();
    begin
      insert into public.connection_invitation(code, created_by, expires_at) values (v_code, v_user_id, v_expiry);
      exit;
    exception when unique_violation then end;
  end loop;
  return query select v_code, v_expiry, null::text;
end;
$$;
revoke all on function public.create_connection_invitation() from public, anon, authenticated;
grant execute on function public.create_connection_invitation() to authenticated;

notify pgrst, 'reload schema';
