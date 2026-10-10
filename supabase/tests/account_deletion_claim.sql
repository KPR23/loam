-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..1' as plan;

select set_config('test.a','00000000-0000-4000-8000-0000000000a1',true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'claim-a@example.invalid');
insert into private.account_deletion_operation(id,account_id,receipt_secret_hash,apple_subject,encrypted_revocation_credential)
  values('00000000-0000-4000-8000-0000000000b1',current_setting('test.a')::uuid,'hash','subject','credential');
insert into private.account_deletion_job(operation_id) values('00000000-0000-4000-8000-0000000000b1');

do $$ declare c record; begin
 select * into c from public.claim_account_deletion_job();
 assert c.operation_id='00000000-0000-4000-8000-0000000000b1','A due deletion job was not claimed';
 assert c.stage='revoke_apple' and c.attempts=1 and c.lease_token is not null,'Claim returned the wrong job state';
 assert (select attempts from private.account_deletion_job where operation_id=c.operation_id)=1,'Claim did not count the attempt';
 assert not exists(select 1 from public.claim_account_deletion_job()),'A leased job was claimed twice';
end $$;
select 'ok 1 - the worker can claim a due deletion job once' as result;
rollback;
