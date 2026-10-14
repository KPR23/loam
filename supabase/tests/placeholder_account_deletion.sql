-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..2' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.e',gen_random_uuid()::text,true),
  set_config('test.f',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'placeholder-deleter@example.invalid');

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select set_config('test.p',(select user_id::text from public.create_placeholder_friend('Zosia')),true);
select set_config('test.r',(select user_id::text from public.create_placeholder_friend('Ola')),true);
select public.save_expense(jsonb_build_object('id',current_setting('test.e'),'amount_minor',1000,'currency','PLN','category','dining','title','Diner',
 'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.p'),'amount_minor',500))));
select public.save_expense(jsonb_build_object('id',current_setting('test.f'),'amount_minor',800,'currency','PLN','category','dining','title','Lunch',
 'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',400),jsonb_build_object('user_id',current_setting('test.r'),'amount_minor',400))));
-- Removing a placeholder settles it with a repayment and keeps its name for the owner's history.
select public.remove_connection(current_setting('test.r')::uuid);
reset role;
do $$ begin
 assert exists(select 1 from public.repayment where from_user=current_setting('test.r')::uuid),'Removal left no settlement to clean up';
end $$;
select 'ok 1 - setup has an active and a removed placeholder with expenses and a settlement' as result;

select public.redact_account_data(current_setting('test.a')::uuid);
do $$ begin
 assert not exists(select 1 from public.profile where display_name in ('Zosia','Ola')),'Placeholder names survived account deletion';
 assert not exists(select 1 from auth.users where id in (current_setting('test.p')::uuid,current_setting('test.r')::uuid)
   and raw_user_meta_data<>'{}'::jsonb),'Placeholder names survived in auth metadata';
 assert not exists(select 1 from public.expense where created_by=current_setting('test.a')::uuid),'Expenses shared only with placeholders survived';
 assert not exists(select 1 from public.repayment where current_setting('test.a')::uuid in (from_user,to_user)),'Placeholder settlement survived';
 assert not exists(select 1 from public.activity_event where audience_user_id in
   (current_setting('test.a')::uuid,current_setting('test.p')::uuid,current_setting('test.r')::uuid)),'Activity survived';
 assert not exists(select 1 from public.user_connection where current_setting('test.p')::uuid in (user_a,user_b)),'Placeholder connection survived';
end $$;
-- Deletion redacts again when the auth user is soft-deleted.
select public.redact_account_data(current_setting('test.a')::uuid);
select 'ok 2 - deleting an account deletes its placeholders and everything only they shared' as result;
rollback;
