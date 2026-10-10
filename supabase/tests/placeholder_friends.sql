-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..4' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'placeholder-owner@example.invalid');

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select set_config('test.p',(select user_id::text from public.create_placeholder_friend('  Zosia  ')),true);
do $$ begin
 assert (select display_name from public.profile where id=current_setting('test.p')::uuid)='Zosia','Name not stored trimmed';
 assert (select managed_by from public.profile where id=current_setting('test.p')::uuid)=current_setting('test.a')::uuid,'Owner not recorded';
 assert exists(select 1 from public.list_connections() where user_id=current_setting('test.p')::uuid),'Placeholder not listed as a friend';
 assert exists(select 1 from public.list_placeholder_friends() where user_id=current_setting('test.p')::uuid),'Placeholder not labelled';
end $$;
select 'ok 1 - a placeholder is a named friend owned by its creator' as result;

select public.save_expense(jsonb_build_object('id',current_setting('test.e'),'amount_minor',1000,'currency','PLN','category','dining','title','Diner',
 'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.p'),'amount_minor',500))));
do $$ begin
 assert (select status from public.expense_share where expense_id=current_setting('test.e')::uuid and user_id=current_setting('test.p')::uuid)='accepted','Placeholder share waited for an answer';
 assert (select amount_minor from public.balance_snapshot() where person_id=current_setting('test.p')::uuid)=500,'Balance with the placeholder missing';
end $$;
select 'ok 2 - expenses split with a placeholder are accepted at once' as result;

do $$ begin
 assert (select error_code is null from public.create_connection_invitation()),'Placeholder used up the free connection';
end $$;
select 'ok 3 - placeholders do not count toward the free connection limit' as result;

select public.remove_connection(current_setting('test.p')::uuid);
do $$ begin
 assert not exists(select 1 from public.balance_snapshot()),'Removing a placeholder left a balance';
 assert not exists(select 1 from public.list_connections() where user_id=current_setting('test.p')::uuid),'Removed placeholder still listed';
end $$;
reset role;
select 'ok 4 - removing a placeholder settles and hides it' as result;
rollback;
