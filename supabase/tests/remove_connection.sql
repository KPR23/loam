-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..3' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true),set_config('test.c',gen_random_uuid()::text,true),
 set_config('test.p1',gen_random_uuid()::text,true),set_config('test.p2',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'remove-a@example.invalid'),
 (current_setting('test.b')::uuid,'remove-b@example.invalid'),(current_setting('test.c')::uuid,'remove-c@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now()),
 (least(current_setting('test.a')::uuid,current_setting('test.c')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.c')::uuid),current_setting('test.a')::uuid,now());

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(jsonb_build_object('id',current_setting('test.e'),'amount_minor',1000,'currency','PLN','category','dining','title','Diner',
 'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',500))));
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.respond_to_expense_share(current_setting('test.e')::uuid,'accept');
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
-- Left unanswered: B's share of one A paid with C too, and A's share of one B paid.
select public.save_expense(jsonb_build_object('id',current_setting('test.p1'),'amount_minor',900,'currency','PLN','category','dining','title','Pizza',
 'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',300),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',300),
 jsonb_build_object('user_id',current_setting('test.c'),'amount_minor',300))));
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.save_expense(jsonb_build_object('id',current_setting('test.p2'),'amount_minor',800,'currency','PLN','category','dining','title','Taxi',
 'spent_at',current_date,'paid_by',current_setting('test.b'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',400),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',400))));
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ declare blocked boolean:=false; begin
 begin perform public.remove_connection(current_setting('test.b')::uuid);
 exception when others then blocked:=true; end;
 assert blocked,'A friend with an open balance was removed';
 assert (select count(*)=1 from public.user_connection where user_a=least(current_setting('test.a')::uuid,current_setting('test.b')::uuid) and user_b=greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid)),'Blocked removal still deleted the connection';
end $$;
select 'ok 1 - a friend who still owes money cannot be removed' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.create_repayment(current_setting('test.a')::uuid,500,'PLN',null,current_date,gen_random_uuid());
select public.remove_connection(current_setting('test.a')::uuid);
do $$ begin
 assert (select count(*)=0 from public.user_connection where user_a=least(current_setting('test.a')::uuid,current_setting('test.b')::uuid) and user_b=greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid)),'Settled friend was not removed';
 assert not private.are_connected(current_setting('test.a')::uuid,current_setting('test.b')::uuid),'Pair still connected';
end $$;
reset role;
select 'ok 2 - either side can remove a settled friend' as result;

do $$ begin
 assert (select status='rejected' from public.expense_share where expense_id=current_setting('test.p1')::uuid and user_id=current_setting('test.b')::uuid),
  'Removed friend''s pending share was left pending';
 assert (select status='rejected' from public.expense_share where expense_id=current_setting('test.p2')::uuid and user_id=current_setting('test.a')::uuid),
  'Pending share on the removed friend''s expense was left pending';
 assert (select status='pending' from public.expense_share where expense_id=current_setting('test.p1')::uuid and user_id=current_setting('test.c')::uuid),
  'A third person''s pending share was declined';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ begin
 assert (select coalesce(sum(amount_minor),0)=300 from public.awaiting_acceptance_snapshot()),'Removed friend still counted as waiting to accept';
end $$;
reset role;
select 'ok 3 - removing a friend declines what was still waiting between the two' as result;
rollback;
