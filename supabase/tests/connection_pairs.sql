-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..2' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'pairs-a@example.invalid'),
 (current_setting('test.b')::uuid,'pairs-b@example.invalid');

do $$ declare denied boolean:=false; begin
 begin insert into public.user_connection(user_a,user_b,created_by)
   values(greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid);
 exception when check_violation then denied:=true; end;
 assert denied,'Non-canonical pair stored';
 assert to_regclass('public.user_connection_unordered_pair_key') is null,'Redundant pair index remains';
end $$;
select 'ok 1 - pairs are stored once in canonical order' as result;

-- Invite from each side in turn so both least/greatest orderings are redeemed.
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select set_config('test.code',(select code from public.create_connection_invitation()),true);
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert (select error_code is null from public.redeem_connection_code(current_setting('test.code'))),'First redeem failed'; end $$;
select set_config('test.code',(select code from public.create_connection_invitation()),true);
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ begin
 assert (select error_code is null from public.redeem_connection_code(current_setting('test.code'))),'Reverse redeem failed';
 assert (select count(*)=1 from public.user_connection),'Duplicate connection rows';
 assert private.are_connected(current_setting('test.a')::uuid,current_setting('test.b')::uuid),'Pair not connected';
 assert to_regprocedure('public.are_connected(uuid,uuid)') is null,'Policy helper still exposed as RPC';
end $$;
reset role;
select 'ok 2 - redeeming from either side keeps one accepted connection' as result;
rollback;
