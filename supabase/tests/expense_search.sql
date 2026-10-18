-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..4' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.c',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'search-a@example.invalid'),
 (current_setting('test.b')::uuid,'search-b@example.invalid'),(current_setting('test.c')::uuid,'search-c@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
-- A: a private coffee, and a groceries trip split with B.
select public.save_expense(jsonb_build_object('amount_minor',900,'currency','PLN','category','other','title','Secret coffee',
  'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
  jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',900))));
select public.save_expense(jsonb_build_object('amount_minor',2000,'currency','PLN','category','other','title','Groceries 100%',
  'note','weekly shop','spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
  jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',1000),
  jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',1000))));

do $$ begin
 assert (select count(*) from public.search_expenses('coffee'))=1,'Owner cannot find own expense';
 assert (select count(*) from public.search_expenses('WEEKLY'))=1,'Note search is not case-insensitive';
 assert (select count(*) from public.search_expenses('c'))=0,'One-character query returned rows';
end $$;
select 'ok 1 - owner finds own expenses' as result;

do $$ begin
 assert (select count(*) from public.search_expenses('100%'))=1,'Literal percent not matched';
 assert (select count(*) from public.search_expenses('%%'))=0,'Wildcards were not escaped';
 assert (select count(*) from public.search_expenses('__'))=0,'Underscore wildcards were not escaped';
end $$;
select 'ok 2 - wildcards are literal' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin
 assert (select count(*) from public.search_expenses('coffee'))=0,'Found an expense B has no share of';
 assert (select count(*) from public.search_expenses('groceries'))=1,'Participant cannot find a shared expense';
end $$;
select 'ok 3 - participants only find expenses they are on' as result;

select set_config('request.jwt.claim.sub',current_setting('test.c'),true);
do $$ begin
 assert (select count(*) from public.search_expenses('coffee'))=0 and (select count(*) from public.search_expenses('groceries'))=0,
   'A stranger can search other people''s expenses';
end $$;
reset role;
do $$ declare denied boolean:=false; begin
 set local role anon;
 begin perform public.search_expenses('coffee'); exception when others then denied:=true; end;
 reset role;
 assert denied,'Anon can run search';
end $$;
select 'ok 4 - strangers and anon get nothing' as result;
rollback;
