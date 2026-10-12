-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..2' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true),set_config('test.f',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'awaiting-a@example.invalid'),
 (current_setting('test.b')::uuid,'awaiting-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());
create function pg_temp.expense(p_id text,p_paid_by text) returns jsonb language sql as $$
  select jsonb_build_object('id',p_id,'amount_minor',900,'currency','PLN','category','dining',
    'spent_at',current_date,'paid_by',p_paid_by,'shares',jsonb_build_array(
    jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',450),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',450)))
$$;

-- A paid one expense; another says B paid, which B hasn't confirmed either.
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense(current_setting('test.e'),current_setting('test.a')));
select public.save_expense(pg_temp.expense(current_setting('test.f'),current_setting('test.b')));
do $$ begin
 assert (select amount_minor=450 and expense_count=1 and currency='PLN' from public.awaiting_acceptance_snapshot()
   where person_id=current_setting('test.b')::uuid),'Unaccepted share missing from what A waits for';
 assert (select count(*)=1 from public.awaiting_acceptance_snapshot()),'Expense B paid counted as owed to A';
 assert not exists(select 1 from public.balance_snapshot()),'Unaccepted share moved the balance';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert not exists(select 1 from public.awaiting_acceptance_snapshot()),'B waits on an expense B did not pay'; end $$;
select 'ok 1 - only the payer waits, and only on unaccepted shares' as result;

select public.respond_to_expense_share(current_setting('test.e')::uuid,'accept');
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ begin
 assert not exists(select 1 from public.awaiting_acceptance_snapshot()),'Accepted share still waiting';
 assert (select amount_minor=450 from public.balance_snapshot() where person_id=current_setting('test.b')::uuid),'Accepted share missing from the balance';
end $$;
reset role;
do $$ begin assert not has_function_privilege('anon','public.awaiting_acceptance_snapshot()','EXECUTE'),'Anonymous users can read waiting balances'; end $$;
select 'ok 2 - accepting moves the share from waiting into the balance' as result;
rollback;
