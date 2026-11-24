-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..3' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'zero-a@example.invalid'),
 (current_setting('test.b')::uuid,'zero-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());
-- Expense fixture created by A: the given payer, A's share and B's share of 1000.
create function pg_temp.expense(p_paid_by text,p_a integer,p_b integer) returns jsonb language sql as $$
  select jsonb_build_object('id',current_setting('test.e'),'amount_minor',p_a+p_b,'currency','PLN','category','dining','title','Diner',
    'spent_at',current_date,'paid_by',current_setting(p_paid_by),'shares',jsonb_build_array(
    jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',p_a),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',p_b)))
$$;
create function pg_temp.share_of_b() returns public.expense_share language sql as $$
  select * from public.expense_share where expense_id=current_setting('test.e')::uuid and user_id=current_setting('test.b')::uuid
$$;
create function pg_temp.version() returns bigint language sql as $$ select version from public.expense where id=current_setting('test.e')::uuid $$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense('test.a',1000,0));
do $$ begin
 assert (pg_temp.share_of_b()).status='accepted','A participant owing 0 was asked to accept';
 assert (pg_temp.share_of_b()).responded_at is not null,'Zero share has no response time';
 assert not (pg_temp.share_of_b()).accepted_via_trust,'Zero share recorded as auto-accepted';
end $$;
select 'ok 1 - a participant who owes 0 is not asked to accept' as result;

select public.save_expense(pg_temp.expense('test.a',500,500),pg_temp.version());
do $$ begin assert (pg_temp.share_of_b()).status='pending','A non-zero share must still wait for an answer'; end $$;
select public.save_expense(pg_temp.expense('test.a',1000,0),pg_temp.version());
do $$ begin assert (pg_temp.share_of_b()).status='accepted','Editing a share down to 0 left it pending'; end $$;
select 'ok 2 - editing a share down to 0 accepts it' as result;

select public.save_expense(pg_temp.expense('test.b',1000,0),pg_temp.version());
do $$ begin assert (pg_temp.share_of_b()).status='pending','The payer must still confirm, even with a 0 share'; end $$;
reset role;
select 'ok 3 - the payer still answers with a 0 share' as result;
rollback;
