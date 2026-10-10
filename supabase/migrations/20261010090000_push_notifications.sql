-- Push notifications mirror the Activity inbox: every unread activity_event is
-- pushed to the audience's registered devices unless they turned that kind off.
--
-- * private.push_device holds one APNs token per device, owned by one account.
-- * private.notification_preference holds the per-category switches the push
--   sender honours, so a muted category never leaves the server.
-- * An insert trigger hands the event to the send-push edge function through
--   pg_net. Delivery is best effort: a failure never blocks the mutation, and
--   the inbox stays the source of truth.

create table private.push_device (
  token text primary key check (token ~ '^[0-9a-f]{32,400}$'),
  user_id uuid not null references auth.users(id) on delete cascade,
  environment text not null check (environment in ('sandbox','production')),
  updated_at timestamptz not null default now()
);
create index push_device_user_idx on private.push_device(user_id);
alter table private.push_device enable row level security;
revoke all on private.push_device from public,anon,authenticated;

create table private.notification_preference (
  user_id uuid primary key references auth.users(id) on delete cascade,
  requests boolean not null default true,
  replies boolean not null default true,
  changes boolean not null default true,
  repayments boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table private.notification_preference enable row level security;
revoke all on private.notification_preference from public,anon,authenticated;

-- Which switch governs each activity kind. _shared/push_content.ts mirrors this.
create function private.notification_category(p_kind text) returns text
language sql immutable set search_path='' as $$
  select case p_kind
    when 'shared' then 'requests' when 'proposal_created' then 'requests'
    when 'accepted' then 'replies' when 'rejected' then 'replies' when 'proposal_accepted' then 'replies'
      when 'proposal_rejected' then 'replies' when 'auto_accepted' then 'replies'
    when 'repayment_recorded' then 'repayments' when 'repayment_reversed' then 'repayments'
    else 'changes' end
$$;
revoke all on function private.notification_category(text) from public,anon,authenticated;

-- A device registers its token for the signed-in account. A token seen before
-- moves to this account, so handing a phone to someone else stops the old
-- account's pushes as soon as the new one signs in.
create function public.register_push_device(p_token text,p_environment text) returns void
language plpgsql security definer set search_path='' as $$
declare v_token text:=lower(trim(coalesce(p_token,'')));
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if v_token !~ '^[0-9a-f]{32,400}$' or p_environment not in ('sandbox','production') then
    raise exception 'Invalid device' using errcode='22023';
  end if;
  insert into private.push_device(token,user_id,environment) values(v_token,auth.uid(),p_environment)
  on conflict(token) do update set user_id=excluded.user_id,environment=excluded.environment,updated_at=now();
  -- Reinstalls mint new tokens; keep only the newest few per account.
  delete from private.push_device where user_id=auth.uid() and token in(
    select token from private.push_device where user_id=auth.uid() order by updated_at desc,token offset 10);
end $$;
revoke all on function public.register_push_device(text,text) from public,anon,authenticated;
grant execute on function public.register_push_device(text,text) to authenticated;

create function public.unregister_push_device(p_token text) returns void
language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  delete from private.push_device where token=lower(trim(coalesce(p_token,''))) and user_id=auth.uid();
end $$;
revoke all on function public.unregister_push_device(text) from public,anon,authenticated;
grant execute on function public.unregister_push_device(text) to authenticated;

create function public.notification_preferences()
returns table(requests boolean,replies boolean,changes boolean,repayments boolean)
language sql stable security definer set search_path='' as $$
  select coalesce(p.requests,true),coalesce(p.replies,true),coalesce(p.changes,true),coalesce(p.repayments,true)
  from (select 1) d left join private.notification_preference p on p.user_id=auth.uid()
  where public.current_account_is_active()
$$;
revoke all on function public.notification_preferences() from public,anon,authenticated;
grant execute on function public.notification_preferences() to authenticated;

create function public.set_notification_preferences(p_requests boolean,p_replies boolean,p_changes boolean,p_repayments boolean)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if p_requests is null or p_replies is null or p_changes is null or p_repayments is null then
    raise exception 'Invalid preferences' using errcode='22023';
  end if;
  insert into private.notification_preference(user_id,requests,replies,changes,repayments)
  values(auth.uid(),p_requests,p_replies,p_changes,p_repayments)
  on conflict(user_id) do update set requests=excluded.requests,replies=excluded.replies,
    changes=excluded.changes,repayments=excluded.repayments,updated_at=now();
end $$;
revoke all on function public.set_notification_preferences(boolean,boolean,boolean,boolean) from public,anon,authenticated;
grant execute on function public.set_notification_preferences(boolean,boolean,boolean,boolean) to authenticated;

-- Everything send-push needs for one event, resolved in one round trip. Returns
-- no row when the event is already read, the account is going away, or the
-- recipient muted its category. Only the service role may call it.
create function public.push_event_context(p_event_id uuid) returns table(
  user_id uuid,kind text,actor_id uuid,actor_name text,recipient_id uuid,recipient_name text,
  expense_id uuid,repayment_id uuid,expense_title text,affected_share_minor integer,currency text,
  badge integer,devices jsonb)
language sql stable security definer set search_path='' as $$
  select a.audience_user_id,a.kind,a.actor_id,public.activity_name(a.actor_id),a.recipient_id,
    case when a.recipient_id is not null then public.activity_name(a.recipient_id) end,
    a.expense_id,a.repayment_id,a.expense_title,a.affected_share_minor,a.currency,
    (select count(*)::integer from (select 1 from public.activity_event u
      where u.audience_user_id=a.audience_user_id and u.read_at is null limit 100) c),
    (select coalesce(jsonb_agg(jsonb_build_object('token',d.token,'environment',d.environment)),'[]'::jsonb)
      from private.push_device d where d.user_id=a.audience_user_id)
  from public.activity_event a
  join public.profile pr on pr.id=a.audience_user_id and pr.deleted_at is null
  left join private.notification_preference p on p.user_id=a.audience_user_id
  where a.id=p_event_id and a.read_at is null and a.audience_user_id<>a.actor_id
    and case private.notification_category(a.kind)
      when 'requests' then coalesce(p.requests,true) when 'replies' then coalesce(p.replies,true)
      when 'repayments' then coalesce(p.repayments,true) else coalesce(p.changes,true) end
    and exists(select 1 from private.push_device d where d.user_id=a.audience_user_id)
$$;
revoke all on function public.push_event_context(uuid) from public,anon,authenticated;
grant execute on function public.push_event_context(uuid) to service_role;

-- Drops tokens APNs reported dead (410 / BadDeviceToken).
create function public.remove_push_devices(p_tokens text[]) returns integer
language plpgsql security definer set search_path='' as $$
declare v_count integer;
begin
  delete from private.push_device where token=any(p_tokens);
  get diagnostics v_count=row_count;
  return v_count;
end $$;
revoke all on function public.remove_push_devices(text[]) from public,anon,authenticated;
grant execute on function public.remove_push_devices(text[]) to service_role;

create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;

-- Runs after commit through pg_net, so a rolled-back mutation never notifies.
-- Quietly does nothing until configure_push_notifications has stored the key,
-- which keeps fresh databases and the test suite free of network calls.
create function private.queue_activity_push() returns trigger
language plpgsql security definer set search_path='' as $$
declare v_url text; v_key text;
begin
  if new.read_at is not null or new.audience_user_id=new.actor_id then return null; end if;
  select decrypted_secret into v_url from vault.decrypted_secrets where name='project_url';
  select decrypted_secret into v_key from vault.decrypted_secrets where name='push_notification_key';
  if v_url is null or v_key is null then return null; end if;
  perform net.http_post(url:=v_url||'/functions/v1/send-push',
    headers:=jsonb_build_object('Content-Type','application/json','X-Push-Key',v_key),
    body:=jsonb_build_object('event_id',new.id),timeout_milliseconds:=10000);
  return null;
exception when others then
  -- Delivery is best effort; never fail the expense or repayment write.
  return null;
end $$;
revoke all on function private.queue_activity_push() from public,anon,authenticated;
create trigger activity_event_push after insert on public.activity_event
  for each row execute function private.queue_activity_push();

create function public.configure_push_notifications(p_project_url text,p_push_key text) returns void
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  if p_project_url !~ '^https://[a-z0-9-]+[.]supabase[.]co$' or length(coalesce(p_push_key,''))<32 then
    raise exception 'Invalid push notification configuration';
  end if;
  select id into v_id from vault.secrets where name='project_url';
  if v_id is null then perform vault.create_secret(p_project_url,'project_url','Supabase project URL for Loam workers');
  else perform vault.update_secret(v_id,p_project_url,'project_url','Supabase project URL for Loam workers'); end if;
  select id into v_id from vault.secrets where name='push_notification_key';
  if v_id is null then perform vault.create_secret(p_push_key,'push_notification_key','Credential for the Loam push sender');
  else perform vault.update_secret(v_id,p_push_key,'push_notification_key','Credential for the Loam push sender'); end if;
end $$;
revoke all on function public.configure_push_notifications(text,text) from public,anon,authenticated;
grant execute on function public.configure_push_notifications(text,text) to service_role;

notify pgrst,'reload schema';
