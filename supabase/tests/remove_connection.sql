-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..2' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'remove-a@example.invalid'),
 (current_setting('test.b')::uuid,'remove-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(jsonb_build_object('id',current_setting('test.e'),'amount_minor',1000,'currency','PLN','category','dining','title','Diner',
 'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',500))));
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.respond_to_expense_share(current_setting('test.e')::uuid,'accept');
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ declare blocked boolean:=false; begin
 begin perform public.remove_connection(current_setting('test.b')::uuid);
 exception when others then blocked:=true; end;
 assert blocked,'A friend with an open balance was removed';
 assert (select count(*)=1 from public.user_connection),'Blocked removal still deleted the connection';
end $$;
select 'ok 1 - a friend who still owes money cannot be removed' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.create_repayment(current_setting('test.a')::uuid,500,'PLN',null,current_date,gen_random_uuid());
select public.remove_connection(current_setting('test.a')::uuid);
do $$ begin
 assert (select count(*)=0 from public.user_connection),'Settled friend was not removed';
 assert not private.are_connected(current_setting('test.a')::uuid,current_setting('test.b')::uuid),'Pair still connected';
end $$;
reset role;
select 'ok 2 - either side can remove a settled friend' as result;
rollback;
