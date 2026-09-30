-- Loam Pro is sold through RevenueCat. The revenuecat-webhook and
-- sync-pro-entitlement functions copy the loam_pro entitlement here, keyed by
-- the Supabase user ID the app logs in to RevenueCat with.
create table private.pro_entitlement (
  account_id uuid primary key references auth.users(id) on delete cascade,
  -- Null for a lifetime purchase.
  expires_at timestamptz,
  synced_at timestamptz not null default now()
);
revoke all on private.pro_entitlement from public, anon, authenticated;

create function private.has_pro(p_account_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from private.pro_entitlement e
    where e.account_id = p_account_id and (e.expires_at is null or e.expires_at > now())
  );
$$;
revoke all on function private.has_pro(uuid) from public, anon, authenticated;

-- Service role only: the functions pass RevenueCat's current state, so replays
-- and out-of-order webhooks converge on the latest answer.
create function public.record_pro_entitlement(p_account_id uuid, p_active boolean, p_expires_at timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from auth.users where id = p_account_id) then return; end if;
  if p_active then
    insert into private.pro_entitlement(account_id, expires_at) values (p_account_id, p_expires_at)
    on conflict (account_id) do update set expires_at = excluded.expires_at, synced_at = now();
  else
    delete from private.pro_entitlement where account_id = p_account_id;
  end if;
end;
$$;
revoke all on function public.record_pro_entitlement(uuid, boolean, timestamptz) from public, anon, authenticated;
grant execute on function public.record_pro_entitlement(uuid, boolean, timestamptz) to service_role;

-- Loam Free includes one connection. Only the person creating an invitation
-- needs Pro to go past it; redeeming a code is never limited, so invitees are
-- never asked to pay. Existing connections stay when Pro lapses.
-- The check runs before the rate limit and before replacing the active code,
-- so a refused request costs nothing and leaves the current code valid.
-- Locking the caller's active codes first serializes this with a redemption:
-- one in flight holds that lock, so the count sees its connection once it
-- commits; one that starts later finds the code already replaced.
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
    where v_user_id in (c.user_a, c.user_b) and c.accepted_at is not null and p.deleted_at is null
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
