# Account deletion operations

## Required environment values

Add these values to both GitHub Actions environments, `staging` and `production`:

- `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `SUPABASE_SERVICE_ROLE_KEY`
- `DELETION_WORKER_KEY`, `DELETION_NOTIFIER_KEY`, `DELETION_MONITOR_KEY` (each at least 32 random characters and distinct)
- `DELETION_CREDENTIAL_ENCRYPTION_KEY` (base64 encoded 32-byte key; keep stable so retained credentials remain decryptable)
- `APPLE_CLIENT_ID`, `APPLE_CLIENT_SECRET`
- `RESEND_API_KEY`, `DELETION_EMAIL_FROM` (a verified sender identity)

The deploy workflow applies migrations, uploads function secrets, deploys all deletion functions, writes the worker and notifier keys to Supabase Vault through the service-role-only RPC, and installs one named minute schedule for each. It checks that incorrect worker, notifier, and monitor credentials receive HTTP 401. The SQL functions and schedule use the `project_url`, `deletion_worker_key`, and `deletion_notifier_key` entries in Vault; do not copy these secrets into migration SQL.

## External silence monitor

Configure an external uptime/heartbeat service to make an HTTPS `GET` every minute to:

`https://<project-ref>.supabase.co/functions/v1/account-deletion-monitor`

Send `X-Deletion-Monitor-Key: <DELETION_MONITOR_KEY>`. Treat any response other than HTTP 200 as an alert. The endpoint returns HTTP 503 for either missing five-minute worker heartbeat, any terminal deletion or email-delivery failure, or a request pending for more than fifteen minutes. It includes last worker and notifier heartbeats, pending count, oldest request, and failure counts. Keep the monitor outside Supabase so a stopped `pg_cron` scheduler is still detected.

Set a five-minute first-check grace period after deployment, then page the operator configured in that external monitoring service on any non-200 response.

## Recovery

Check health first using the monitor endpoint. In the SQL editor, inspect an affected request without selecting its receipt hash, Apple credential, or encrypted email:

```sql
select o.id as operation_id, o.accepted_at, o.failed_at, o.failure_reason,
       j.stage, j.stage_attempts, j.attempts, j.run_after, j.progress
from private.account_deletion_operation o
join private.account_deletion_job j on j.operation_id = o.id
where o.failed_at is not null or j.stage = 'needs_attention'
order by o.accepted_at;
```

After fixing the recorded provider/configuration issue, resume the current stage with an auditable reason:

```sql
select public.recover_account_deletion('<operation UUID>', 'Fixed the Apple client configuration');
```

Recovery is possible while the encrypted Apple credential remains within its 30-day retention window. If that window expires, the request remains explicitly failed and must be handled with the account owner and Apple authorization; it is never reported as complete. Do not manually mark a deletion complete. Avatar objects are removed before Supabase Auth is soft-deleted. The soft-delete tombstone disables sign-in and preserves the user identifier referenced by other participants' shared history; account RLS also blocks stale access tokens. Shared expenses remain for their other participants with the deleted-user display name.

Email delivery is tracked separately from deletion. The encrypted recipient is retained for up to seven days or twelve attempts and is erased on successful delivery or expiry. A missing verified email does not create an outbox row; the in-app receipt screen still confirms completion.

## Staging acceptance before production

Use a disposable Apple account in the staging app. Give it private and shared expenses plus multiple avatar objects. Confirm the app stores its receipt before submission, sign out, force-quit, relaunch, and observe processing then completion. Confirm private data is removed, shared history remains for the other participants, Auth is disabled, and every avatar object is gone. Test concurrent worker requests, an Apple 400, a storage failure, a lost submission response, an expired/missing receipt, and a Resend outage. Check that deletion can finish while email retries continue, and that notification delivery is idempotent.

Stop each cron job for more than five minutes and force a terminal worker failure in staging. Confirm the external monitor alerts on both. Then run the documented recovery and verify progress resumes. A successful `pg_cron` run alone is not proof of deletion completion.

## App Review notes

Navigation: **Profile → Personal details → Delete account**. After fresh Apple confirmation, account access closes immediately. Deletion usually completes within a few minutes. The signed-out screen restores the secure deletion receipt after relaunch and shows processing, needs attention, completion, or temporary service unavailability. Completion appears in-app; a separate email is sent where a verified address is available. Shared expenses remain visible to other participants with the deleted-user label.
