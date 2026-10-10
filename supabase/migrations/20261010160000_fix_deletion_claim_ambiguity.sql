-- claim_account_deletion_job returns a table with `attempts` and `stage` columns, which plpgsql
-- also declares as variables. Its `attempts = attempts + 1` was therefore ambiguous and raised
-- an error whenever a job was due, so the worker answered 500 claim_failed every minute and no
-- deletion ever left revoke_apple. Same body, with the job's columns qualified.
create or replace function public.claim_account_deletion_job()
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
      lease_token = v_token, attempts = j.attempts + 1,
      stage_attempts = j.stage_attempts + 1, heartbeat_at = now(), updated_at = now()
      where j.operation_id = v_job.operation_id;
    return query select v_job.operation_id, o.account_id, v_job.stage,
      o.encrypted_revocation_credential, v_job.stage_attempts + 1, v_token
      from private.account_deletion_operation o where o.id = v_job.operation_id;
  end loop;
end $$;
revoke all on function public.claim_account_deletion_job() from public, anon, authenticated;
grant execute on function public.claim_account_deletion_job() to service_role;
