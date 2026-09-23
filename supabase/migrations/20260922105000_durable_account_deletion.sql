-- This migration precedes the account-deletion hardening migration, which
-- depends on its private functions.
-- Account deletion is an asynchronous, one-way operation.  These tables are
-- deliberately private: application roles can only ask the Edge Function for
-- the minimal status protected by the receipt secret.
create schema if not exists private;
create table if not exists private.account_deletion_operation (
  id uuid primary key,
  account_id uuid not null references auth.users(id),
  receipt_secret_hash text not null,
  apple_subject text not null,
  encrypted_revocation_credential text not null,
  accepted_at timestamptz not null default now(),
  completed_at timestamptz,
  failed_at timestamptz,
  failure_reason text,
  unique (account_id)
);

create table if not exists private.account_deletion_job (
  operation_id uuid primary key references private.account_deletion_operation(id) on delete cascade,
  stage text not null default 'revoke_apple' check (stage in ('revoke_apple', 'delete_auth', 'delete_avatars', 'complete')),
  attempts integer not null default 0,
  run_after timestamptz not null default now(),
  leased_until timestamptz,
  progress jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

revoke all on all tables in schema private from public, anon, authenticated;

-- Used by RLS and SECURITY DEFINER mutation functions.  Do not use JWT claims
-- for this: a token minted before acceptance remains cryptographically valid.
create or replace function public.current_account_is_active()
returns boolean language sql stable security definer set search_path = '' as $$
  select auth.uid() is not null and exists (
    select 1 from public.profile where id = auth.uid() and deleted_at is null
  )
$$;
revoke all on function public.current_account_is_active() from public;
grant execute on function public.current_account_is_active() to authenticated;

create or replace function public.is_household_member(hid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.current_account_is_active() and exists (
    select 1 from public.household_member where household_id = hid and user_id = auth.uid()
  )
$$;
create or replace function public.is_household_owner(hid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.current_account_is_active() and exists (
    select 1 from public.household_member where household_id = hid and user_id = auth.uid() and role = 'owner'
  )
$$;

create or replace function private.can_read_expense_shares(p_expense_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.current_account_is_active() and (
    exists (select 1 from public.expense where id = p_expense_id and created_by = auth.uid()) or
    exists (select 1 from public.expense_share where expense_id = p_expense_id and user_id = auth.uid())
  )
$$;

drop policy if exists "expense_select_participant" on public.expense;
create policy "expense_select_active_participant" on public.expense for select to authenticated using (
  public.current_account_is_active() and (created_by = auth.uid() or exists (select 1 from public.expense_share s where s.expense_id = expense.id and s.user_id = auth.uid()))
);
drop policy if exists "share_update_own_acceptance" on public.expense_share;
create policy "share_update_active_own_acceptance" on public.expense_share for update to authenticated
  using (public.current_account_is_active() and user_id = auth.uid()) with check (public.current_account_is_active() and user_id = auth.uid());
drop policy if exists "trust_select_own" on public.expense_share_trust;
drop policy if exists "trust_insert_own" on public.expense_share_trust;
drop policy if exists "trust_delete_own" on public.expense_share_trust;
create policy "trust_select_active_own" on public.expense_share_trust for select to authenticated using (public.current_account_is_active() and user_id = auth.uid());
create policy "trust_insert_active_own" on public.expense_share_trust for insert to authenticated with check (public.current_account_is_active() and user_id = auth.uid() and public.is_household_member(household_id));
create policy "trust_delete_active_own" on public.expense_share_trust for delete to authenticated using (public.current_account_is_active() and user_id = auth.uid());

-- Called only by the service-role Edge Function after it has verified both the
-- caller's session and a new Apple authorization.  The row lock makes retries
-- with the same account converge on one operation.
create or replace function private.accept_account_deletion(
  p_operation_id uuid, p_account_id uuid, p_receipt_secret_hash text,
  p_apple_subject text, p_encrypted_credential text
) returns table(operation_id uuid, accepted_at timestamptz, complete boolean)
language plpgsql security definer set search_path = '' as $$
declare v_existing private.account_deletion_operation%rowtype;
begin
  perform 1 from public.profile where id = p_account_id for update;
  if not found then raise exception 'Account not found'; end if;
  select * into v_existing from private.account_deletion_operation where account_id = p_account_id for update;
  if found then
    if v_existing.id <> p_operation_id then
      -- Never reveal the existing receipt. A caller who lost the response must
      -- use the receipt it created before submitting.
      raise exception 'Deletion already accepted';
    end if;
    return query select v_existing.id, v_existing.accepted_at, v_existing.completed_at is not null;
    return;
  end if;
  perform public.redact_account_data(p_account_id);
  insert into private.account_deletion_operation(id, account_id, receipt_secret_hash, apple_subject, encrypted_revocation_credential)
  values (p_operation_id, p_account_id, p_receipt_secret_hash, p_apple_subject, p_encrypted_credential);
  insert into private.account_deletion_job(operation_id) values (p_operation_id);
  return query select p_operation_id, now(), false;
end $$;
revoke all on function private.accept_account_deletion(uuid,uuid,text,text,text) from public, anon, authenticated;

create or replace function private.deletion_status(p_operation_id uuid, p_receipt_secret_hash text)
returns table(status text, accepted_at timestamptz, completed_at timestamptz)
language sql security definer set search_path = '' as $$
 select case when o.completed_at is not null then 'complete' when o.failed_at is not null then 'failed' else 'processing' end,
        o.accepted_at, o.completed_at
 from private.account_deletion_operation o
 where o.id = p_operation_id and o.receipt_secret_hash = p_receipt_secret_hash
$$;
revoke all on function private.deletion_status(uuid,text) from public, anon, authenticated;

create or replace function public.claim_account_deletion_job()
returns table(operation_id uuid, account_id uuid, stage text, credential text, attempts integer)
language plpgsql security definer set search_path = '' as $$
declare v_job private.account_deletion_job%rowtype;
begin
  select * into v_job from private.account_deletion_job where run_after <= now()
    and (leased_until is null or leased_until < now()) and stage <> 'complete'
    order by run_after for update skip locked limit 1;
  if not found then return; end if;
  update private.account_deletion_job set leased_until = now() + interval '55 seconds', attempts = attempts + 1, updated_at = now() where operation_id = v_job.operation_id;
  return query select v_job.operation_id, o.account_id, v_job.stage, o.encrypted_revocation_credential, v_job.attempts from private.account_deletion_operation o where o.id = v_job.operation_id;
end $$;
revoke all on function public.claim_account_deletion_job() from public, anon, authenticated;
grant execute on function public.claim_account_deletion_job() to service_role;

create or replace function public.advance_account_deletion_job(p_operation_id uuid, p_stage text, p_success boolean, p_detail text default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_success then
    update private.account_deletion_job set stage = p_stage, leased_until = null, run_after = now(), updated_at = now() where operation_id = p_operation_id;
    if p_stage = 'complete' then update private.account_deletion_operation set completed_at = now(), encrypted_revocation_credential = '' where id = p_operation_id; end if;
  else
    update private.account_deletion_job set leased_until = null, run_after = now() + least(interval '1 hour', interval '1 minute' * power(2, least(attempts, 6))), updated_at = now(), progress = progress || jsonb_build_object('last_error', coalesce(p_detail, 'unknown')) where operation_id = p_operation_id;
  end if;
end $$;
revoke all on function public.advance_account_deletion_job(uuid,text,boolean,text) from public, anon, authenticated;
grant execute on function public.advance_account_deletion_job(uuid,text,boolean,text) to service_role;

-- Update the remaining exposed policies to reject stale sessions.  Existing
-- survivor policies still permit reads of shared historical rows.
alter table public.profile force row level security;
drop policy if exists "profile_select_own" on public.profile;
drop policy if exists "profile_insert_own" on public.profile;
drop policy if exists "profile_select_self_or_connection" on public.profile;
create policy "profile_select_self_or_active_connection" on public.profile for select to authenticated using (
  public.current_account_is_active() and (id = auth.uid() or public.are_connected(auth.uid(), id))
);
drop policy if exists "profile_update_own" on public.profile;
create policy "profile_update_editable_own" on public.profile for update to authenticated
  using (public.current_account_is_active() and id = auth.uid())
  with check (public.current_account_is_active() and id = auth.uid() and deleted_at is null);

-- Storage has its own policy namespace, so gate every avatar operation too.
drop policy if exists "avatar_select_self_or_connection" on storage.objects;
create policy "avatar_select_active_self_or_connection" on storage.objects for select to authenticated using (
  bucket_id = 'avatars' and public.current_account_is_active() and
  ((storage.foldername(name))[1] = auth.uid()::text or public.are_connected(auth.uid(), (storage.foldername(name))[1]::uuid))
);
drop policy if exists "avatar_upload_own" on storage.objects;
create policy "avatar_upload_active_own" on storage.objects for insert to authenticated with check (
  bucket_id = 'avatars' and public.current_account_is_active() and (storage.foldername(name))[1] = auth.uid()::text
);
drop policy if exists "avatar_delete_own" on storage.objects;
create policy "avatar_delete_active_own" on storage.objects for delete to authenticated using (
  bucket_id = 'avatars' and public.current_account_is_active() and (storage.foldername(name))[1] = auth.uid()::text
);

-- Credentials and receipts are removed after completion by the service-only
-- worker; operational records are purged after 30 days.
notify pgrst, 'reload schema';
