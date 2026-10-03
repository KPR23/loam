-- Run with `supabase test db` after applying the account deletion migrations.
begin;
select plan(29);

select ok(not has_function_privilege('anon', 'public.claim_account_deletion_job()', 'EXECUTE'), 'anon cannot claim deletion jobs');
select ok(not has_function_privilege('authenticated', 'public.claim_account_deletion_job()', 'EXECUTE'), 'authenticated cannot claim deletion jobs');
select ok(has_function_privilege('service_role', 'public.claim_account_deletion_job()', 'EXECUTE'), 'service role can claim deletion jobs');

select ok(not has_function_privilege('anon', 'public.advance_account_deletion_job(uuid,text,uuid,text,boolean,text)', 'EXECUTE'), 'anon cannot advance deletion jobs');
select ok(not has_function_privilege('authenticated', 'public.advance_account_deletion_job(uuid,text,uuid,text,boolean,text)', 'EXECUTE'), 'authenticated cannot advance deletion jobs');
select ok(has_function_privilege('service_role', 'public.advance_account_deletion_job(uuid,text,uuid,text,boolean,text)', 'EXECUTE'), 'service role can advance deletion jobs');

select ok(not has_function_privilege('anon', 'public.recover_account_deletion(uuid,text)', 'EXECUTE'), 'anon cannot recover deletion jobs');
select ok(not has_function_privilege('authenticated', 'public.recover_account_deletion(uuid,text)', 'EXECUTE'), 'authenticated cannot recover deletion jobs');
select ok(has_function_privilege('service_role', 'public.recover_account_deletion(uuid,text)', 'EXECUTE'), 'service role can recover deletion jobs');
select ok(not has_function_privilege('authenticated', 'public.account_deletion_health()', 'EXECUTE'), 'health data is not public');
select ok(not has_function_privilege('anon', 'public.account_deletion_health()', 'EXECUTE'), 'health data is not anonymous');
select ok(has_function_privilege('service_role', 'public.account_deletion_health()', 'EXECUTE'), 'service role can read health data');

select ok(not has_function_privilege('anon', 'public.configure_account_deletion_scheduler(text,text,text)', 'EXECUTE'), 'anon cannot configure the scheduler');
select ok(not has_function_privilege('authenticated', 'public.configure_account_deletion_scheduler(text,text,text)', 'EXECUTE'), 'authenticated cannot configure the scheduler');
select ok(has_function_privilege('service_role', 'public.configure_account_deletion_scheduler(text,text,text)', 'EXECUTE'), 'service role can configure the scheduler');

select ok(not has_function_privilege('anon', 'public.accept_account_deletion(uuid,uuid,text,text,text,text)', 'EXECUTE'), 'anon cannot submit privileged acceptance');
select ok(not has_function_privilege('authenticated', 'public.accept_account_deletion(uuid,uuid,text,text,text,text)', 'EXECUTE'), 'authenticated cannot submit privileged acceptance');
select ok(has_function_privilege('service_role', 'public.accept_account_deletion(uuid,uuid,text,text,text,text)', 'EXECUTE'), 'service role can submit verified acceptance');

select ok(not has_function_privilege('anon', 'public.claim_account_deletion_notifications()', 'EXECUTE'), 'anon cannot claim notification jobs');
select ok(has_function_privilege('service_role', 'public.claim_account_deletion_notifications()', 'EXECUTE'), 'service role can claim notification jobs');
select ok(not has_function_privilege('authenticated', 'public.finish_account_deletion_notification(uuid,uuid,boolean,text)', 'EXECUTE'), 'authenticated cannot update notification delivery');
select ok(has_function_privilege('service_role', 'public.finish_account_deletion_notification(uuid,uuid,boolean,text)', 'EXECUTE'), 'service role can update notification delivery');

select ok(not has_function_privilege('anon', 'public.record_account_deletion_heartbeat(integer,integer,integer)', 'EXECUTE'), 'anon cannot forge worker heartbeats');
select ok(not has_function_privilege('anon', 'public.record_account_deletion_notifier_heartbeat(integer,integer,integer)', 'EXECUTE'), 'anon cannot forge notifier heartbeats');
select ok(not has_function_privilege('authenticated', 'public.purge_completed_account_deletions()', 'EXECUTE'), 'authenticated cannot purge receipts');
select ok(has_function_privilege('service_role', 'public.purge_completed_account_deletions()', 'EXECUTE'), 'service role can purge receipts');

select ok(to_regprocedure('public.accept_account_deletion(uuid,uuid,text,text,text)') is null, 'superseded acceptance overload is gone');
select ok(to_regprocedure('public.advance_account_deletion_job(uuid,text,boolean,text)') is null, 'lease-less job transition overload is gone');

select ok(
  (select pg_get_constraintdef(oid) from pg_constraint where conname = 'account_deletion_job_stage_check') like '%delete_analytics%',
  'deletion jobs can enter the analytics deletion stage'
);

select * from finish();
rollback;
