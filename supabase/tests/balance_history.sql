-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..1' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'history-a@example.invalid'),
 (current_setting('test.b')::uuid,'history-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());

-- A records an expense that B paid. A's own share is accepted; B hasn't answered.
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(jsonb_build_object('id',current_setting('test.e'),'amount_minor',1000,'currency','EUR','category','dining',
 'title','Dinner','spent_at',current_date,'paid_by',current_setting('test.b'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',500))));
do $$ begin
 assert (select status='accepted' and payer_status='pending' and currency='EUR'
   from public.balance_history(current_setting('test.b')::uuid) where id=current_setting('test.e')::uuid),
   'History hides that the payer has not accepted';
 assert not exists(select 1 from public.balance_snapshot()),'An unaccepted payer share moved the balance';
end $$;
select 'ok 1 - history returns the payer''s answer that the balance depends on' as result;

rollback;
