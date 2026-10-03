-- Account deletion also erases the user's PostHog person, events and
-- recordings. The worker runs this stage between avatar and auth deletion.
alter table private.account_deletion_job drop constraint if exists account_deletion_job_stage_check;
alter table private.account_deletion_job add constraint account_deletion_job_stage_check
  check (stage in ('revoke_apple', 'delete_avatars', 'delete_analytics', 'delete_auth', 'complete', 'needs_attention'));

-- Jobs already past avatar deletion would otherwise finish without erasing
-- analytics. Rewinding is safe: auth deletion tolerates an already-deleted
-- user, and an older worker holding a lease fails its stale transition.
update private.account_deletion_job set stage = 'delete_analytics', stage_attempts = 0, updated_at = now()
where stage = 'delete_auth';
update private.account_deletion_job set progress = jsonb_set(progress, '{last_failure,stage}', '"delete_analytics"')
where stage = 'needs_attention' and progress->'last_failure'->>'stage' = 'delete_auth';

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
      coalesce((j.progress->'retry_counts'->>'delete_analytics')::integer, 0) +
      coalesce((j.progress->'retry_counts'->>'delete_auth')::integer, 0)
    ), 0),
    (select coalesce(jsonb_object_agg(stage, stage_count), '{}'::jsonb)
      from (select stage, count(*) as stage_count from private.account_deletion_job group by stage) totals)
  from private.account_deletion_job j join private.account_deletion_operation o on o.id = j.operation_id
$$;
revoke all on function public.account_deletion_health() from public, anon, authenticated;
grant execute on function public.account_deletion_health() to service_role;
