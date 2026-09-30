-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..4' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.c',gen_random_uuid()::text,true),set_config('test.d',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'pro-a@example.invalid'),
 (current_setting('test.b')::uuid,'pro-b@example.invalid'),(current_setting('test.c')::uuid,'pro-c@example.invalid'),
 (current_setting('test.d')::uuid,'pro-d@example.invalid');
create function pg_temp.invite_error() returns text language sql as $$
  select error_code from public.create_connection_invitation()
$$;
create function pg_temp.redeem_invite_from(p_inviter text) returns void language plpgsql as $$
declare v_code text;
begin
  perform set_config('request.jwt.claim.sub',current_setting(p_inviter),true);
  select code into v_code from public.create_connection_invitation();
  assert v_code is not null,'Invitation was refused';
  perform set_config('request.jwt.claim.sub',current_setting('test.b'),true);
  assert (select error_code from public.redeem_connection_code(v_code)) is null,'Redeeming was refused';
end $$;

set local role authenticated;
-- A has no connections, so a free invitation works; B joins it.
select pg_temp.redeem_invite_from('test.a');
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ begin
 assert pg_temp.invite_error()='pro_required','Free account invited a second connection';
end $$;
select 'ok 1 - a free account cannot invite past one connection' as result;

-- B already has A but joins C and D: invitees are never limited.
select pg_temp.redeem_invite_from('test.c');
select pg_temp.redeem_invite_from('test.d');
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin
 assert (select count(*) from public.list_connections())=3,'Joining a code was limited';
end $$;
select 'ok 2 - joining a code never needs Pro' as result;

do $$ declare denied boolean:=false; begin
 begin perform public.record_pro_entitlement(auth.uid(),true,null);
 exception when insufficient_privilege then denied:=true; end;
 assert denied,'Clients can grant themselves Pro';
end $$;
select 'ok 3 - clients cannot record entitlements' as result;

reset role;
select public.record_pro_entitlement(current_setting('test.a')::uuid,true,now()+interval '1 month');
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ begin
 assert pg_temp.invite_error() is null,'Pro account could not invite';
end $$;
reset role;
select public.record_pro_entitlement(current_setting('test.a')::uuid,true,now()-interval '1 day');
set local role authenticated;
do $$ begin
 assert pg_temp.invite_error()='pro_required','Expired Pro still invites';
end $$;
select 'ok 4 - an active entitlement lifts the limit and expiry restores it' as result;
rollback;
