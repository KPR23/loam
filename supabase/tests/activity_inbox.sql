-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..4' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'inbox-a@example.invalid'),
 (current_setting('test.b')::uuid,'inbox-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 select least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),
 current_setting('test.a')::uuid,now();
-- A paid 900, split with B. Callers override fields.
create function pg_temp.expense(p_changes jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('id',current_setting('test.e'),'amount_minor',900,'currency','PLN','category','dining',
    'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
    jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',450),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',450)))||p_changes
$$;
create function pg_temp.inbox() returns text[] language sql as $$
  select coalesce(array_agg(kind order by kind),'{}') from public.activity_inbox()
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense());
do $$ begin
 assert pg_temp.inbox()='{}' and public.activity_unread_count()=0,'Own actions reach the inbox';
 assert exists(select 1 from public.activity_page() where kind='shared'),'Own actions left the history';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin
 assert pg_temp.inbox()=array['shared'] and public.activity_unread_count()=1,'Shared expense missing from the inbox';
end $$;
select 'ok 1 - other people''s events are unread and own actions are not' as result;

select public.respond_to_expense_share(current_setting('test.e')::uuid,'accept');
do $$ begin
 assert pg_temp.inbox()='{}','Answering left the request unread';
 assert (select count(*)=2 from public.expense_activity(current_setting('test.e')::uuid)),'Read events left the expense history';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ begin assert pg_temp.inbox()=array['accepted'],'Owner missed the answer'; end $$;
select public.save_expense(pg_temp.expense('{"title":"Dinner"}'),(select version from public.expense where id=current_setting('test.e')::uuid));
do $$ begin assert pg_temp.inbox()='{}','Own edit left the answer it replaces unread'; end $$;
select 'ok 2 - a newer event about the same expense replaces older unread ones' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select set_config('test.edited',(select id::text from public.activity_inbox() where kind='edited'),true);
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.mark_activity_read(array[current_setting('test.edited')::uuid]);
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert pg_temp.inbox()=array['edited'],'Another user marked the event read'; end $$;
select public.mark_activity_read(array[current_setting('test.edited')::uuid]);
do $$ begin assert pg_temp.inbox()='{}' and public.activity_unread_count()=0,'Marking read left the event unread'; end $$;
select 'ok 3 - only the audience can mark an event read' as result;

reset role;
do $$ begin
 assert not has_function_privilege('anon','public.activity_inbox(uuid)','EXECUTE'),'Anonymous users can read the inbox';
 assert not has_function_privilege('anon','public.mark_activity_read(uuid[])','EXECUTE'),'Anonymous users can mark activity read';
 assert not has_function_privilege('authenticated','private.mark_replaced_activity_read()','EXECUTE'),'Clients can call the read trigger';
 assert not has_column_privilege('authenticated','public.activity_event','read_at','UPDATE'),'Clients can write read_at directly';
end $$;
select 'ok 4 - read state is only reachable through the RPCs' as result;
rollback;
