-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..3' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true),set_config('test.f',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'seen-a@example.invalid'),
 (current_setting('test.b')::uuid,'seen-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 select least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),
 current_setting('test.a')::uuid,now();
-- A paid 900, split with B.
create function pg_temp.expense(p_id text) returns jsonb language sql as $$
  select jsonb_build_object('id',p_id,'amount_minor',900,'currency','PLN','category','dining',
    'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
    jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',450),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',450)))
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense(current_setting('test.e')));
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert public.activity_unseen_count()=1,'New event not counted'; end $$;
select public.mark_activity_seen(now());
do $$ begin
 assert public.activity_unseen_count()=0,'Seen event still counted';
 assert (select count(*)=1 from public.activity_inbox()),'Seeing an event read it';
end $$;
select 'ok 1 - seeing the inbox clears the badge but keeps the events unread' as result;

-- Events newer than what the viewer loaded keep counting.
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense(current_setting('test.f')));
reset role;
update public.activity_event set occurred_at=now()+interval '1 minute'
 where expense_id=current_setting('test.f')::uuid and audience_user_id=current_setting('test.b')::uuid;
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.mark_activity_seen(now());
do $$ begin assert public.activity_unseen_count()=1,'An event newer than the cutoff was seen'; end $$;
reset role;
do $$ declare e uuid; begin
 select id into e from public.activity_event where expense_id=current_setting('test.f')::uuid and audience_user_id=current_setting('test.b')::uuid;
 insert into private.push_device(token,user_id,environment) values(repeat('ab',32),current_setting('test.b')::uuid,'sandbox');
 assert (select badge from public.push_event_context(e))=1,'Push badge counts seen events';
end $$;
select 'ok 2 - only events up to the cutoff are seen, and pushes badge the unseen count' as result;

-- Another account cannot mark B's events seen.
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.mark_activity_seen(now()+interval '1 hour');
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert public.activity_unseen_count()=1,'Another user marked the event seen'; end $$;
reset role;
do $$ begin
 assert not has_function_privilege('anon','public.mark_activity_seen(timestamptz)','EXECUTE'),'Anonymous users can mark activity seen';
 assert not has_column_privilege('authenticated','public.activity_event','seen_at','UPDATE'),'Clients can write seen_at directly';
end $$;
select 'ok 3 - seen state is only reachable through the RPC for own events' as result;
rollback;
