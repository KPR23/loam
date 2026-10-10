-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..3' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'auto-a@example.invalid'),
 (current_setting('test.b')::uuid,'auto-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());
-- Expense fixture: A paid 1000, split A 500 / B 500. Callers override fields.
create function pg_temp.expense(p_changes jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('id',current_setting('test.e'),'amount_minor',1000,'currency','PLN','category','dining','title','Diner',
    'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
    jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',500)))||p_changes
$$;
create function pg_temp.status_of_b() returns public.expense_share_status language sql as $$
  select status from public.expense_share where expense_id=current_setting('test.e')::uuid and user_id=current_setting('test.b')::uuid
$$;
create function pg_temp.version() returns bigint language sql as $$ select version from public.expense where id=current_setting('test.e')::uuid $$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense());
do $$ begin assert pg_temp.status_of_b()='pending','Without the setting a share waits for an answer'; end $$;
select 'ok 1 - shares stay pending unless the recipient opted in' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.set_auto_accept_expenses(true);
do $$ begin
 assert (select auto_accept_expenses from public.profile where id=current_setting('test.b')::uuid),'Setting was not saved';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense(jsonb_build_object('amount_minor',1100,'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',600)))),pg_temp.version());
do $$ begin
 assert pg_temp.status_of_b()='accepted','A changed amount was not auto-accepted';
 assert (select accepted_via_trust from public.expense_share where expense_id=current_setting('test.e')::uuid and user_id=current_setting('test.b')::uuid),'Auto-accept not recorded as trust';
end $$;
select 'ok 2 - an opted-in recipient accepts new and changed amounts' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.set_auto_accept_expenses(false);
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense(jsonb_build_object('amount_minor',1200,'shares',jsonb_build_array(jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',700)))),pg_temp.version());
do $$ begin assert pg_temp.status_of_b()='pending','A changed amount stayed accepted with the setting off'; end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.respond_to_expense_share(current_setting('test.e')::uuid,'reject');
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense(jsonb_build_object('amount_minor',1200,'note','Receipt','shares',jsonb_build_array(jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',700)))),pg_temp.version());
do $$ begin assert pg_temp.status_of_b()='rejected','Unrelated edit erased a rejection'; end $$;
reset role;
select 'ok 3 - a rejected share stays rejected' as result;
rollback;
