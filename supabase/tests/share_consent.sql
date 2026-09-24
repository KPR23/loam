-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..3' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'consent-a@example.invalid'),
 (current_setting('test.b')::uuid,'consent-b@example.invalid');
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

do $$ begin
 assert not has_function_privilege('authenticated','private.save_expense_as(uuid,jsonb,bigint,uuid)','EXECUTE'),'Clients can save as another user';
end $$;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense());
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.respond_to_expense_share(current_setting('test.e')::uuid,'accept');
select public.create_repayment(current_setting('test.a')::uuid,500,'PLN',null,current_date,gen_random_uuid());
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense('{"title":"Dinner"}'),pg_temp.version());
do $$ begin
 assert pg_temp.status_of_b()='accepted','Typo fix reset accepted share';
 assert not exists(select 1 from public.balance_snapshot()),'Typo fix flipped a settled balance';
end $$;
select 'ok 1 - edits that leave an obligation unchanged keep acceptance' as result;

select public.save_expense(pg_temp.expense(jsonb_build_object('amount_minor',1100,'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',600)))),pg_temp.version());
do $$ begin assert pg_temp.status_of_b()='pending','Changed amount kept old consent'; end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.respond_to_expense_share(current_setting('test.e')::uuid,'reject');
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense(jsonb_build_object('amount_minor',1100,'note','Receipt attached','shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',600)))),pg_temp.version());
do $$ begin assert pg_temp.status_of_b()='rejected','Unrelated edit erased a rejection'; end $$;
select public.save_expense(pg_temp.expense(jsonb_build_object('amount_minor',1100,'paid_by',current_setting('test.b'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',600)))),pg_temp.version());
do $$ begin assert pg_temp.status_of_b()='pending','Payer change kept old consent'; end $$;
select 'ok 2 - changed amounts, payers and responses are asked again' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select set_config('test.proposal',public.create_expense_edit_proposal(current_setting('test.e')::uuid,pg_temp.version(),
 pg_temp.expense(jsonb_build_object('amount_minor',1200,'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',700)))))::text,true);
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.respond_to_edit_proposal(current_setting('test.proposal')::uuid,true);
do $$ begin
 assert pg_temp.status_of_b()='accepted','Proposer must re-accept their own proposal';
 assert (select not accepted_via_trust from public.expense_share where expense_id=current_setting('test.e')::uuid and user_id=current_setting('test.b')::uuid),'Proposal acceptance recorded as trust';
end $$;
reset role;
select 'ok 3 - an applied proposal counts as the proposer''s consent' as result;
rollback;
