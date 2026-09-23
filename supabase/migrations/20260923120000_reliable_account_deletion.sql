-- Reliable deletion worker operations. Keep receipt status truthful, scope
-- retries to each stage, retain recoverable Apple credentials for 30 days,
-- and install one Vault-protected scheduler job.
alter table private.account_deletion_job
  add column if not exists stage_attempts integer not null default 0,
  add column if not exists heartbeat_at timestamptz;
alter table private.account_deletion_job drop constraint if exists account_deletion_job_stage_check;
alter table private.account_deletion_job add constraint account_deletion_job_stage_check
  check (stage in ('revoke_apple', 'delete_avatars', 'delete_auth', 'complete', 'needs_attention'));

-- Older code called exhausted jobs complete while setting failed_at and
-- discarding the Apple credential. Reclassify them so status/monitoring remain
-- honest; they are not recoverable without fresh Apple authorization.
update private.account_deletion_job j set stage = 'needs_attention', updated_at = now()
  from private.account_deletion_operation o
  where j.operation_id = o.id and j.stage = 'complete'
    and o.failed_at is not null and o.completed_at is null;
update private.account_deletion_job set progress = progress - 'last_error'
  where progress ? 'last_error';

alter table private.account_deletion_operation
  add column if not exists credential_expires_at timestamptz default (now() + interval '30 days'),
  add column if not exists encrypted_notification_address text not null default '',
  add column if not exists notification_address_expires_at timestamptz default (now() + interval '30 days');

create table if not exists private.account_deletion_notification (
  operation_id uuid primary key references private.account_deletion_operation(id) on delete cascade,
  encrypted_address text not null,
  attempts integer not null default 0,
  run_after timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '7 days'),
  delivered_at timestamptz,
  failed_at timestamptz,
  last_error_code text,
  updated_at timestamptz not null default now()
);
alter table private.account_deletion_notification add column if not exists lease_token uuid;
alter table private.account_deletion_notification add column if not exists leased_until timestamptz;
revoke all on private.account_deletion_notification from public, anon, authenticated;

create or replace function public.accept_account_deletion(
  p_operation_id uuid, p_account_id uuid, p_receipt_secret_hash text,
  p_apple_subject text, p_encrypted_credential text, p_encrypted_notification_address text
) returns table(operation_id uuid, accepted_at timestamptz, complete boolean)
language plpgsql security definer set search_path = '' as $$
declare v_result record;
begin
  select * into v_result from private.accept_account_deletion(
    p_operation_id, p_account_id, p_receipt_secret_hash, p_apple_subject, p_encrypted_credential
  );
  update private.account_deletion_operation set encrypted_notification_address = coalesce(p_encrypted_notification_address, '')
    where id = p_operation_id and completed_at is null;
  return query select v_result.operation_id, v_result.accepted_at, v_result.complete;
end $$;
revoke all on function public.accept_account_deletion(uuid,uuid,text,text,text,text) from public, anon, authenticated;
grant execute on function public.accept_account_deletion(uuid,uuid,text,text,text,text) to service_role;

create or replace function public.claim_account_deletion_notifications()
returns table(operation_id uuid, encrypted_address text, attempt integer, lease_token uuid)
language plpgsql security definer set search_path = '' as $$
declare v_row private.account_deletion_notification%rowtype;
begin
  for v_row in select n.* from private.account_deletion_notification n
    join private.account_deletion_operation o on o.id = n.operation_id
    where n.delivered_at is null and n.failed_at is null and n.run_after <= now()
      and n.expires_at > now() and o.completed_at is not null
      and (n.leased_until is null or n.leased_until < now())
    order by n.run_after for update of n skip locked limit 2
  loop
    update private.account_deletion_notification set attempts = attempts + 1,
      lease_token = gen_random_uuid(), leased_until = now() + interval '45 seconds', updated_at = now()
      where account_deletion_notification.operation_id = v_row.operation_id;
    return query select v_row.operation_id, v_row.encrypted_address, v_row.attempts + 1,
      (select n.lease_token from private.account_deletion_notification n where n.operation_id = v_row.operation_id);
  end loop;
  update private.account_deletion_notification set failed_at = now(), encrypted_address = '',
    lease_token = null, leased_until = null, last_error_code = 'delivery_deadline_exceeded', updated_at = now()
    where delivered_at is null and failed_at is null and expires_at <= now();
end $$;
revoke all on function public.claim_account_deletion_notifications() from public, anon, authenticated;
grant execute on function public.claim_account_deletion_notifications() to service_role;

create or replace function public.finish_account_deletion_notification(p_operation_id uuid, p_lease_token uuid, p_success boolean, p_error_code text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_changed integer;
begin
  if p_success then
    update private.account_deletion_notification set delivered_at = now(), encrypted_address = '',
      last_error_code = null, lease_token = null, leased_until = null, updated_at = now()
      where operation_id = p_operation_id and lease_token = p_lease_token and delivered_at is null and failed_at is null;
  else
    update private.account_deletion_notification set
      run_after = now() + least(interval '6 hours', interval '5 minutes' * power(2, least(attempts - 1, 6))),
      failed_at = case when attempts >= 12 or expires_at <= now() then now() else null end,
      encrypted_address = case when attempts >= 12 or expires_at <= now() then '' else encrypted_address end,
      lease_token = null, leased_until = null,
      last_error_code = left(coalesce(p_error_code, 'delivery_failed'), 80), updated_at = now()
      where operation_id = p_operation_id and lease_token = p_lease_token and delivered_at is null and failed_at is null;
  end if;
  get diagnostics v_changed = row_count;
  return v_changed = 1;
end $$;
revoke all on function public.finish_account_deletion_notification(uuid,uuid,boolean,text) from public, anon, authenticated;
grant execute on function public.finish_account_deletion_notification(uuid,uuid,boolean,text) to service_role;

create table if not exists private.account_deletion_worker_heartbeat (
  worker_name text primary key check (worker_name in ('account-deletion-worker', 'account-deletion-notifier')),
  last_seen_at timestamptz not null,
  last_processed integer not null default 0,
  last_retrying integer not null default 0,
  last_failed integer not null default 0
);
revoke all on private.account_deletion_worker_heartbeat from public, anon, authenticated;

create or replace function public.record_account_deletion_heartbeat(p_processed integer, p_retrying integer, p_failed integer)
returns void language sql security definer set search_path = '' as $$
  insert into private.account_deletion_worker_heartbeat(worker_name, last_seen_at, last_processed, last_retrying, last_failed)
  values ('account-deletion-worker', now(), greatest(p_processed, 0), greatest(p_retrying, 0), greatest(p_failed, 0))
  on conflict (worker_name) do update set last_seen_at = excluded.last_seen_at,
    last_processed = excluded.last_processed, last_retrying = excluded.last_retrying, last_failed = excluded.last_failed
$$;
revoke all on function public.record_account_deletion_heartbeat(integer,integer,integer) from public, anon, authenticated;
grant execute on function public.record_account_deletion_heartbeat(integer,integer,integer) to service_role;

create or replace function public.record_account_deletion_notifier_heartbeat(p_processed integer, p_retrying integer, p_failed integer)
returns void language sql security definer set search_path = '' as $$
  insert into private.account_deletion_worker_heartbeat(worker_name, last_seen_at, last_processed, last_retrying, last_failed)
  values ('account-deletion-notifier', now(), greatest(p_processed, 0), greatest(p_retrying, 0), greatest(p_failed, 0))
  on conflict (worker_name) do update set last_seen_at = excluded.last_seen_at,
    last_processed = excluded.last_processed, last_retrying = excluded.last_retrying, last_failed = excluded.last_failed
$$;
revoke all on function public.record_account_deletion_notifier_heartbeat(integer,integer,integer) from public, anon, authenticated;
grant execute on function public.record_account_deletion_notifier_heartbeat(integer,integer,integer) to service_role;

update private.account_deletion_operation
set credential_expires_at = accepted_at + interval '30 days'
where encrypted_revocation_credential <> '' and credential_expires_at is null;

-- Remove storage-owned files before asking Auth to delete the owner. This also
-- safely redirects jobs accepted by the earlier stage order.
update private.account_deletion_job set stage = 'delete_avatars', updated_at = now()
where stage = 'delete_auth';

-- Correct the earlier hardening migration's dropped function ACL. PostgreSQL
-- grants EXECUTE to PUBLIC on newly created functions unless it is revoked.
revoke all on function public.claim_account_deletion_job() from public, anon, authenticated;
grant execute on function public.claim_account_deletion_job() to service_role;

drop function if exists public.claim_account_deletion_job();
create function public.claim_account_deletion_job()
returns table(operation_id uuid, account_id uuid, stage text, credential text, attempts integer, lease_token uuid)
language plpgsql security definer set search_path = '' as $$
declare v_token uuid; v_job private.account_deletion_job%rowtype;
begin
  update private.account_deletion_job j set stage = 'needs_attention', updated_at = now()
    from private.account_deletion_operation o
    where o.id = j.operation_id and j.stage = 'revoke_apple'
      and o.credential_expires_at <= now() and o.encrypted_revocation_credential <> '';
  update private.account_deletion_operation o set failed_at = now(), failure_reason = 'recovery_credential_expired'
    from private.account_deletion_job j where j.operation_id = o.id
      and j.stage = 'needs_attention' and o.failed_at is null;
  for v_job in
    select j.* from private.account_deletion_job j
    join private.account_deletion_operation o on o.id = j.operation_id
    where j.run_after <= now() and (j.leased_until is null or j.leased_until < now())
      and j.stage not in ('complete', 'needs_attention')
    order by j.run_after for update of j skip locked limit 3
  loop
    v_token := gen_random_uuid();
    update private.account_deletion_job j set leased_until = now() + interval '5 minutes',
      lease_token = v_token, attempts = attempts + 1,
      stage_attempts = stage_attempts + 1, heartbeat_at = now(), updated_at = now()
      where j.operation_id = v_job.operation_id;
    return query select v_job.operation_id, o.account_id, v_job.stage,
      o.encrypted_revocation_credential, v_job.stage_attempts + 1, v_token
      from private.account_deletion_operation o where o.id = v_job.operation_id;
  end loop;
end $$;
revoke all on function public.claim_account_deletion_job() from public, anon, authenticated;
grant execute on function public.claim_account_deletion_job() to service_role;

create or replace function public.advance_account_deletion_job(
  p_operation_id uuid, p_expected_stage text, p_lease_token uuid,
  p_next_stage text, p_success boolean, p_detail text default null
) returns boolean language plpgsql security definer set search_path = '' as $$
declare v_updated integer; v_attempts integer; v_code text;
begin
  if p_success then
    update private.account_deletion_job set stage = p_next_stage, stage_attempts = 0,
      leased_until = null, lease_token = null, run_after = now(), heartbeat_at = now(),
      updated_at = now(), progress = progress || jsonb_build_object(p_expected_stage, jsonb_build_object('completed_at', now()))
      where operation_id = p_operation_id and stage = p_expected_stage
        and lease_token = p_lease_token and leased_until > now();
  else
    update private.account_deletion_job set leased_until = null, lease_token = null,
      run_after = now() + least(interval '1 hour', interval '1 minute' * power(2, least(stage_attempts, 6))),
      heartbeat_at = now(), updated_at = now(),
      progress = progress || jsonb_build_object(
        'retry_counts', coalesce(progress->'retry_counts', '{}'::jsonb) || jsonb_build_object(
          p_expected_stage, coalesce((progress->'retry_counts'->>p_expected_stage)::integer, 0) + 1
        ),
        'last_failure', jsonb_build_object('stage', p_expected_stage, 'code', left(coalesce(p_detail, 'unknown'), 80), 'at', now())
      )
      where operation_id = p_operation_id and stage = p_expected_stage
        and lease_token = p_lease_token and leased_until > now();
  end if;
  get diagnostics v_updated = row_count;
  if v_updated = 1 and p_success and p_expected_stage = 'revoke_apple' then
    update private.account_deletion_operation set encrypted_revocation_credential = '', credential_expires_at = null
    where id = p_operation_id;
  end if;
  if v_updated = 1 and p_success and p_next_stage = 'complete' then
    insert into private.account_deletion_notification(operation_id, encrypted_address)
      select id, encrypted_notification_address from private.account_deletion_operation
      where id = p_operation_id and encrypted_notification_address <> ''
        and notification_address_expires_at > now()
      on conflict (operation_id) do nothing;
    update private.account_deletion_operation set completed_at = now(), encrypted_revocation_credential = '', credential_expires_at = null,
      encrypted_notification_address = '', notification_address_expires_at = null
    where id = p_operation_id;
  elsif v_updated = 1 and not p_success then
    select stage_attempts into v_attempts from private.account_deletion_job where operation_id = p_operation_id;
    if v_attempts >= 10 then
      update private.account_deletion_job set stage = 'needs_attention', leased_until = null,
        lease_token = null, updated_at = now() where operation_id = p_operation_id;
      update private.account_deletion_operation set failed_at = now(),
        failure_reason = 'stage_retry_exhausted:' || p_expected_stage
        where id = p_operation_id;
    end if;
  end if;
  return v_updated = 1;
end $$;
revoke all on function public.advance_account_deletion_job(uuid,text,uuid,text,boolean,text) from public, anon, authenticated;
grant execute on function public.advance_account_deletion_job(uuid,text,uuid,text,boolean,text) to service_role;

-- Operator recovery: clear the terminal marker but preserve the live stage and
-- retry evidence. The caller supplies an audited reason, never a credential.
create or replace function public.recover_account_deletion(p_operation_id uuid, p_reason text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_changed integer;
begin
  update private.account_deletion_job j set stage = case when j.stage = 'needs_attention' then
      coalesce(progress->'last_failure'->>'stage', 'revoke_apple') else stage end,
      stage_attempts = 0, run_after = now(), leased_until = null, lease_token = null,
      updated_at = now(), progress = j.progress || jsonb_build_object('recovered_at', now(), 'recovery_reason', left(coalesce(p_reason, ''), 300))
    from private.account_deletion_operation o
    where j.operation_id = p_operation_id and j.operation_id = o.id and j.stage = 'needs_attention'
      and (coalesce(j.progress->'last_failure'->>'stage', 'revoke_apple') <> 'revoke_apple'
        or (o.encrypted_revocation_credential <> '' and o.credential_expires_at > now()));
  get diagnostics v_changed = row_count;
  if v_changed = 1 then update private.account_deletion_operation set failed_at = null, failure_reason = null where id = p_operation_id; end if;
  return v_changed = 1;
end $$;
revoke all on function public.recover_account_deletion(uuid,text) from public, anon, authenticated;
grant execute on function public.recover_account_deletion(uuid,text) to service_role;

create or replace function public.account_deletion_health()
returns table(last_heartbeat timestamptz, last_notifier_heartbeat timestamptz, oldest_pending timestamptz, terminal_failures bigint, pending_count bigint, email_failures bigint, retry_count bigint, stage_counts jsonb)
language sql security definer set search_path = '' as $$
  select (select h.last_seen_at from private.account_deletion_worker_heartbeat h where h.worker_name = 'account-deletion-worker'),
    (select h.last_seen_at from private.account_deletion_worker_heartbeat h where h.worker_name = 'account-deletion-notifier'), min(o.accepted_at) filter (where j.stage <> 'complete'),
    count(*) filter (where j.stage = 'needs_attention'),
    count(*) filter (where j.stage <> 'complete'),
    (select count(*) from private.account_deletion_notification n where n.failed_at is not null),
    coalesce(sum(
      coalesce((j.progress->'retry_counts'->>'revoke_apple')::integer, 0) +
      coalesce((j.progress->'retry_counts'->>'delete_avatars')::integer, 0) +
      coalesce((j.progress->'retry_counts'->>'delete_auth')::integer, 0)
    ), 0),
    (select coalesce(jsonb_object_agg(stage, stage_count), '{}'::jsonb)
      from (select stage, count(*) as stage_count from private.account_deletion_job group by stage) totals)
  from private.account_deletion_job j join private.account_deletion_operation o on o.id = j.operation_id
$$;
revoke all on function public.account_deletion_health() from public, anon, authenticated;
grant execute on function public.account_deletion_health() to service_role;

-- Retain failed-operation credentials only for a bounded recovery window.
-- This does not mark a failed deletion complete; the receipt remains failed.
create or replace function public.purge_completed_account_deletions()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  update private.account_deletion_operation set encrypted_revocation_credential = '', credential_expires_at = null
    where failed_at is not null and credential_expires_at < now() and encrypted_revocation_credential <> '';
  update private.account_deletion_operation set encrypted_notification_address = '', notification_address_expires_at = null
    where notification_address_expires_at < now() and encrypted_notification_address <> '';
  delete from private.account_deletion_operation where completed_at < now() - interval '30 days';
  get diagnostics v_count = row_count;
  return v_count;
end $$;
revoke all on function public.purge_completed_account_deletions() from public, anon, authenticated;
grant execute on function public.purge_completed_account_deletions() to service_role;

-- Configure Vault and install named schedules only after deployed secrets are
-- present. This keeps fresh databases from starting an unusable schedule.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
create extension if not exists supabase_vault with schema vault;
create or replace function public.configure_account_deletion_scheduler(p_project_url text, p_worker_key text, p_notifier_key text)
returns void language plpgsql security definer set search_path = '' as $$
declare v_secret_id uuid; v_job_id bigint;
begin
  if p_project_url !~ '^https://[a-z0-9-]+[.]supabase[.]co$' or length(p_worker_key) < 32 or length(p_notifier_key) < 32 then
    raise exception 'Invalid account deletion scheduler configuration';
  end if;
  select id into v_secret_id from vault.secrets where name = 'project_url';
  if v_secret_id is null then perform vault.create_secret(p_project_url, 'project_url', 'Supabase project URL for Loam deletion workers');
  else perform vault.update_secret(v_secret_id, p_project_url, 'project_url', 'Supabase project URL for Loam deletion workers'); end if;
  select id into v_secret_id from vault.secrets where name = 'deletion_worker_key';
  if v_secret_id is null then perform vault.create_secret(p_worker_key, 'deletion_worker_key', 'Credential for the Loam account deletion worker');
  else perform vault.update_secret(v_secret_id, p_worker_key, 'deletion_worker_key', 'Credential for the Loam account deletion worker'); end if;
  select id into v_secret_id from vault.secrets where name = 'deletion_notifier_key';
  if v_secret_id is null then perform vault.create_secret(p_notifier_key, 'deletion_notifier_key', 'Credential for the Loam account deletion notifier');
  else perform vault.update_secret(v_secret_id, p_notifier_key, 'deletion_notifier_key', 'Credential for the Loam account deletion notifier'); end if;

  if not exists (select 1 from cron.job where jobname = 'loam-account-deletion-worker') then
    select cron.schedule('loam-account-deletion-worker', '* * * * *', $job$
      select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/account-deletion-worker',
        headers := jsonb_build_object('Content-Type', 'application/json', 'X-Deletion-Worker-Key',
          (select decrypted_secret from vault.decrypted_secrets where name = 'deletion_worker_key')),
        body := '{}'::jsonb, timeout_milliseconds := 55000
      );
    $job$) into v_job_id;
  end if;
  if not exists (select 1 from cron.job where jobname = 'loam-account-deletion-notifier') then
    select cron.schedule('loam-account-deletion-notifier', '* * * * *', $job$
      select net.http_post(
        url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/account-deletion-notifier',
        headers := jsonb_build_object('Content-Type', 'application/json', 'X-Deletion-Notifier-Key',
          (select decrypted_secret from vault.decrypted_secrets where name = 'deletion_notifier_key')),
        body := '{}'::jsonb, timeout_milliseconds := 30000
      );
    $job$) into v_job_id;
  end if;
end $$;
revoke all on function public.configure_account_deletion_scheduler(text,text,text) from public, anon, authenticated;
grant execute on function public.configure_account_deletion_scheduler(text,text,text) to service_role;

notify pgrst, 'reload schema';
