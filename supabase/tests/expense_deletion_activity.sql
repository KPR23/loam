-- TAP-compatible, rollback-only integration tests. Use supabase test db.
-- Creators may delete accepted shared expenses; every participant must see it.
begin;
set local plpgsql.check_asserts=on;
select '1..1' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'delete-a@example.invalid'),
 (current_setting('test.b')::uuid,'delete-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(jsonb_build_object('id',current_setting('test.e'),'amount_minor',1000,'currency','PLN','category','dining',
 'title','Dinner','spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',400),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',600))));
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.respond_to_expense_share(current_setting('test.e')::uuid,'accept');
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
delete from public.expense where id=current_setting('test.e')::uuid;
do $$ begin assert not exists(select 1 from public.balance_snapshot()),'Deleted expense still affects balances'; end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin
 assert exists(select 1 from public.activity_page() where kind='deleted' and expense_id=current_setting('test.e')::uuid
   and actor_id=current_setting('test.a')::uuid and expense_title='Dinner' and affected_share_minor=600 and expense_total_minor=1000),
   'Participant cannot see who deleted the accepted expense';
end $$;
reset role;
select 'ok 1 - deleting an accepted expense is recorded for every participant' as result;
rollback;
