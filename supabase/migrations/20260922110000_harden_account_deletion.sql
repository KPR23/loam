-- Corrective hardening for durable deletion.  Keep the private schema out of
-- PostgREST; Edge Functions use these service-role-only public entry points.
create or replace function public.accept_account_deletion(
  p_operation_id uuid, p_account_id uuid, p_receipt_secret_hash text,
  p_apple_subject text, p_encrypted_credential text
) returns table(operation_id uuid, accepted_at timestamptz, complete boolean)
language sql security definer set search_path = '' as $$
  select * from private.accept_account_deletion(p_operation_id, p_account_id, p_receipt_secret_hash, p_apple_subject, p_encrypted_credential)
$$;
revoke all on function public.accept_account_deletion(uuid,uuid,text,text,text) from public, anon, authenticated;
grant execute on function public.accept_account_deletion(uuid,uuid,text,text,text) to service_role;

create or replace function public.deletion_status(p_operation_id uuid, p_receipt_secret_hash text)
returns table(status text, accepted_at timestamptz, completed_at timestamptz)
language sql security definer set search_path = '' as $$
  select * from private.deletion_status(p_operation_id, p_receipt_secret_hash)
$$;
revoke all on function public.deletion_status(uuid,text) from public, anon, authenticated;
grant execute on function public.deletion_status(uuid,text) to service_role;

-- All permissive policies are now constrained by this restrictive policy. It
-- closes stale JWT access without weakening surviving participants' history.
do $$
declare t text;
begin
  foreach t in array array['profile','household','household_member','household_invite','expense','expense_share','expense_edit_proposal','expense_share_trust','recurring_rule','settlement','repayment','user_connection','connection_invitation','activity_event'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop policy if exists active_account_required on public.%I', t);
      execute format('create policy active_account_required on public.%I as restrictive for all to authenticated using (public.current_account_is_active()) with check (public.current_account_is_active())', t);
    end if;
  end loop;
end $$;
drop policy if exists active_account_required on storage.objects;
create policy active_account_required on storage.objects as restrictive for all to authenticated
  using (public.current_account_is_active()) with check (public.current_account_is_active());

-- SECURITY DEFINER RPCs bypass table RLS, so they must make the lifecycle
-- check themselves as well.
create or replace function public.balance_snapshot()
returns table(person_id uuid, display_name text, currency text, amount_minor integer)
language sql stable security definer set search_path = public as $$
  with obligations as (
    select case when e.paid_by = auth.uid() then s.user_id else e.paid_by end as other_id, e.currency,
      case when e.paid_by = auth.uid() then s.amount_minor else -s.amount_minor end as delta
    from public.expense e join public.expense_share s on s.expense_id = e.id
      join public.expense_share payer on payer.expense_id = e.id and payer.user_id = e.paid_by
    where public.current_account_is_active() and s.user_id <> e.paid_by and (e.paid_by = auth.uid() or s.user_id = auth.uid()) and s.status = 'accepted' and payer.status = 'accepted'
  ), payments as (
    select case when r.to_user = auth.uid() then r.from_user else r.to_user end as other_id, r.currency,
      case when r.to_user = auth.uid() then -r.amount_minor else r.amount_minor end as delta
    from public.repayment r where public.current_account_is_active() and auth.uid() in (r.from_user, r.to_user) and r.reversed_at is null
  ), net as (select other_id, currency, sum(delta)::integer as amount_minor from (select * from obligations union all select * from payments) x group by other_id, currency)
  select n.other_id, coalesce(p.display_name, 'Connected person'), n.currency, n.amount_minor from net n join public.profile p on p.id = n.other_id where n.amount_minor <> 0
$$;

create or replace function public.create_repayment(p_to_user_id uuid, p_amount_minor integer, p_currency text, p_note text, p_paid_at date, p_operation_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_debt integer;
begin
  if not public.current_account_is_active() or p_amount_minor <= 0 or p_to_user_id = auth.uid() or p_currency not in ('PLN','EUR','USD') then raise exception 'Invalid repayment'; end if;
  select id into v_id from public.repayment where operation_id = p_operation_id and from_user = auth.uid(); if v_id is not null then return v_id; end if;
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_to_user_id::text || p_currency, 0));
  if not public.current_account_is_active() then raise exception 'Account is closed'; end if;
  select -amount_minor into v_debt from public.balance_snapshot() where person_id = p_to_user_id and currency = p_currency;
  if coalesce(v_debt, 0) < p_amount_minor then raise exception 'Repayment exceeds confirmed debt'; end if;
  insert into public.repayment(from_user, to_user, amount_minor, currency, note, paid_at, operation_id) values (auth.uid(), p_to_user_id, p_amount_minor, p_currency, p_note, p_paid_at, p_operation_id) returning id into v_id;
  return v_id;
end $$;

create or replace function public.reverse_repayment(p_repayment_id uuid, p_operation_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.current_account_is_active() then raise exception 'Account is closed'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_repayment_id::text, 1));
  if exists (select 1 from public.repayment where id = p_repayment_id and from_user = auth.uid() and reversal_operation_id = p_operation_id) then return; end if;
  update public.repayment set reversed_at = now(), reversal_operation_id = p_operation_id where id = p_repayment_id and from_user = auth.uid() and reversed_at is null;
  if not found then raise exception 'Repayment not found or already reversed'; end if;
end $$;

-- A lease is identified by an unguessable token; stale workers cannot advance
-- a job after another worker has claimed it.
alter table private.account_deletion_job add column if not exists lease_token uuid;
drop function if exists public.claim_account_deletion_job();
create or replace function public.claim_account_deletion_job()
returns table(operation_id uuid, account_id uuid, stage text, credential text, attempts integer, lease_token uuid)
language plpgsql security definer set search_path = '' as $$
declare v_job private.account_deletion_job%rowtype; v_token uuid := gen_random_uuid();
begin
  select * into v_job from private.account_deletion_job where run_after <= now()
    and (leased_until is null or leased_until < now()) and stage <> 'complete'
    order by run_after for update skip locked limit 1;
  if not found then return; end if;
  update private.account_deletion_job set leased_until = now() + interval '5 minutes', lease_token = v_token, attempts = attempts + 1, updated_at = now() where operation_id = v_job.operation_id;
  return query select v_job.operation_id, o.account_id, v_job.stage, o.encrypted_revocation_credential, v_job.attempts, v_token from private.account_deletion_operation o where o.id = v_job.operation_id;
end $$;

create or replace function public.advance_account_deletion_job(p_operation_id uuid, p_expected_stage text, p_lease_token uuid, p_next_stage text, p_success boolean, p_detail text default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_updated integer;
begin
  if p_success then
    update private.account_deletion_job set stage = p_next_stage, leased_until = null, lease_token = null, run_after = now(), updated_at = now()
      where operation_id = p_operation_id and stage = p_expected_stage and lease_token = p_lease_token and leased_until > now();
  else
    update private.account_deletion_job set leased_until = null, lease_token = null,
      run_after = now() + least(interval '1 hour', interval '1 minute' * power(2, least(attempts, 6))),
      updated_at = now(), progress = progress || jsonb_build_object('last_error', coalesce(p_detail, 'unknown'))
      where operation_id = p_operation_id and stage = p_expected_stage and lease_token = p_lease_token and leased_until > now();
  end if;
  get diagnostics v_updated = row_count;
  if v_updated = 1 and p_success and p_next_stage = 'complete' then
    update private.account_deletion_operation set completed_at = now(), encrypted_revocation_credential = '' where id = p_operation_id;
  end if;
  return v_updated = 1;
end $$;
revoke all on function public.advance_account_deletion_job(uuid,text,uuid,text,boolean,text) from public, anon, authenticated;
grant execute on function public.advance_account_deletion_job(uuid,text,uuid,text,boolean,text) to service_role;

-- Remove completed receipts after 30 days. Failed jobs retain only encrypted
-- credentials and require alerting/operational intervention, never silent loss.
create or replace function public.purge_completed_account_deletions()
returns integer language plpgsql security definer set search_path = '' as $$
declare v_count integer;
begin
  delete from private.account_deletion_operation where completed_at < now() - interval '30 days';
  get diagnostics v_count = row_count; return v_count;
end $$;
revoke all on function public.purge_completed_account_deletions() from public, anon, authenticated;
grant execute on function public.purge_completed_account_deletions() to service_role;

notify pgrst, 'reload schema';
