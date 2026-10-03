-- Account-to-account connection codes. All code access goes through the RPCs
-- below so an invitation can never be enumerated through table reads.

alter table public.connection_invitation
  alter column expires_at set default now() + interval '24 hours';

update public.connection_invitation
set expires_at = least(expires_at, created_at + interval '24 hours')
where accepted_at is null and expires_at > created_at + interval '24 hours';

-- Pre-release UUID-style invitations cannot meet the public code contract.
update public.connection_invitation
set expires_at = now()
where accepted_at is null and (length(code) <> 8 or code !~ '^[23456789ABCDEFGHJKLMNPQRSTUVWXYZ]+$');

-- Earlier connections were unique only by their stored orientation, so a pair
-- could exist twice as (A, B) and (B, A). Retain the accepted record when
-- possible before enforcing uniqueness regardless of orientation.
with ranked_connections as (
  select id,
         row_number() over (
           partition by least(user_a, user_b), greatest(user_a, user_b)
           order by (accepted_at is not null) desc, accepted_at desc nulls last, created_at, id
         ) as row_number
  from public.user_connection
)
delete from public.user_connection as connection
using ranked_connections
where connection.id = ranked_connections.id
  and ranked_connections.row_number > 1;

create unique index if not exists user_connection_unordered_pair_key
  on public.user_connection (least(user_a, user_b), greatest(user_a, user_b));

create table if not exists public.connection_code_rate_limit (
  account_id uuid not null references auth.users(id) on delete cascade,
  action text not null check (action in ('attempt', 'create')),
  occurred_at timestamptz not null default now()
);
create index if not exists connection_code_rate_limit_lookup
  on public.connection_code_rate_limit (account_id, action, occurred_at desc);
alter table public.connection_code_rate_limit enable row level security;

create or replace function public.normalized_connection_code(p_code text)
returns text language sql immutable set search_path = '' as $$
  select upper(regexp_replace(coalesce(p_code, ''), '[[:space:]-]', '', 'g'));
$$;

create or replace function public.assert_connection_code_rate(p_action text, p_limit integer, p_window interval)
returns void language plpgsql security definer set search_path = '' as $$
declare v_user_id uuid := (select auth.uid()); v_count integer;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_user_id::text || ':' || p_action, 0));
  select count(*) into v_count from public.connection_code_rate_limit
    where account_id = v_user_id and action = p_action and occurred_at > now() - p_window;
  if v_count >= p_limit then
    raise exception 'Too many attempts. Please try again later.';
  end if;
  insert into public.connection_code_rate_limit(account_id, action) values (v_user_id, p_action);
end;
$$;

create or replace function public.connection_code_value()
returns text language plpgsql volatile set search_path = '' as $$
declare alphabet constant text := '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'; result text := ''; i integer;
begin
  for i in 1..8 loop result := result || substr(alphabet, 1 + floor(random() * length(alphabet))::integer, 1); end loop;
  return result;
end;
$$;

create or replace function public.list_connections()
returns table(user_id uuid, display_name text)
language sql stable security definer set search_path = '' as $$
  select case when c.user_a = auth.uid() then c.user_b else c.user_a end,
         coalesce(p.display_name, 'Connected person')
  from public.user_connection c join public.profile p on p.id = case when c.user_a = auth.uid() then c.user_b else c.user_a end
  where auth.uid() in (c.user_a, c.user_b) and c.accepted_at is not null and p.deleted_at is null
  order by coalesce(p.display_name, 'Connected person') collate "C";
$$;

create or replace function public.create_connection_invitation()
returns table(code text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare v_user_id uuid := (select auth.uid()); v_code text; v_expiry timestamptz := now() + interval '24 hours';
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from public.profile where id = v_user_id and deleted_at is null) then raise exception 'Account unavailable'; end if;
  perform public.assert_connection_code_rate('create', 10, interval '1 hour');
  -- Replacing an invitation is explicit consent and invalidates its old code.
  update public.connection_invitation set expires_at = now() where created_by = v_user_id and accepted_at is null and expires_at > now();
  loop
    v_code := public.connection_code_value();
    begin
      insert into public.connection_invitation(code, created_by, expires_at) values (v_code, v_user_id, v_expiry);
      exit;
    exception when unique_violation then end;
  end loop;
  return query select v_code, v_expiry;
end;
$$;

create or replace function public.revoke_connection_invitation()
returns void language sql security definer set search_path = '' as $$
  update public.connection_invitation set expires_at = now()
  where created_by = auth.uid() and accepted_at is null and expires_at > now();
$$;

create or replace function public.active_connection_invitation()
returns table(code text, expires_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select i.code, i.expires_at from public.connection_invitation i
  where i.created_by = auth.uid() and i.accepted_at is null and i.expires_at > now()
  order by i.created_at desc limit 1;
$$;

create or replace function public.preview_connection_code(p_code text)
returns table(inviter_name text)
language plpgsql security definer set search_path = '' as $$
declare v_code text := public.normalized_connection_code(p_code);
begin
  perform public.assert_connection_code_rate('attempt', 10, interval '15 minutes');
  if length(v_code) <> 8 then raise exception 'That code is unavailable.'; end if;
  return query select p.display_name from public.connection_invitation i join public.profile p on p.id = i.created_by
    where i.code = v_code and i.accepted_at is null and i.expires_at > now() and p.deleted_at is null;
  if not found then raise exception 'That code is unavailable.'; end if;
end;
$$;

create or replace function public.redeem_connection_code(p_code text)
returns table(user_id uuid, display_name text)
language plpgsql security definer set search_path = '' as $$
declare v_user_id uuid := (select auth.uid()); v_code text := public.normalized_connection_code(p_code); v_inviter uuid; v_name text;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  perform public.assert_connection_code_rate('attempt', 10, interval '15 minutes');
  if length(v_code) <> 8 then raise exception 'That code is unavailable.'; end if;
  select i.created_by, p.display_name into v_inviter, v_name from public.connection_invitation i join public.profile p on p.id = i.created_by
    where i.code = v_code and i.accepted_at is null and i.expires_at > now() and p.deleted_at is null for update of i;
  if not found then raise exception 'That code is unavailable.'; end if;
  if v_inviter = v_user_id then raise exception 'You cannot connect with yourself.'; end if;
  if not exists (select 1 from public.profile where id = v_user_id and deleted_at is null) then raise exception 'Account unavailable'; end if;
  insert into public.user_connection(user_a, user_b, created_by, accepted_at)
  values (least(v_user_id, v_inviter), greatest(v_user_id, v_inviter), v_user_id, now())
  on conflict (least(user_a, user_b), greatest(user_a, user_b)) do update set accepted_at = coalesce(user_connection.accepted_at, excluded.accepted_at);
  update public.connection_invitation set accepted_at = now(), invited_user_id = v_user_id where code = v_code;
  return query select v_inviter, coalesce(v_name, 'Connected person');
end;
$$;

revoke all on public.connection_code_rate_limit from public, anon, authenticated;
revoke all on function public.assert_connection_code_rate(text, integer, interval), public.list_connections(), public.create_connection_invitation(), public.revoke_connection_invitation(), public.active_connection_invitation(), public.preview_connection_code(text), public.redeem_connection_code(text) from public, anon, authenticated;
grant execute on function public.list_connections(), public.create_connection_invitation(), public.revoke_connection_invitation(), public.active_connection_invitation(), public.preview_connection_code(text), public.redeem_connection_code(text) to authenticated;
notify pgrst, 'reload schema';
