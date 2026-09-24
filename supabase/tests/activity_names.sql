-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..3' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.c',gen_random_uuid()::text,true),set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'names-a@example.invalid'),
 (current_setting('test.b')::uuid,'names-b@example.invalid'),(current_setting('test.c')::uuid,'names-c@example.invalid');
-- A is connected to B and C; B and C are not connected to each other.
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 select least(current_setting('test.a')::uuid,u),greatest(current_setting('test.a')::uuid,u),current_setting('test.a')::uuid,now()
 from unnest(array[current_setting('test.b')::uuid,current_setting('test.c')::uuid]) u;
update public.profile set display_name='Anna' where id in (current_setting('test.a')::uuid,current_setting('test.c')::uuid);
update public.profile set display_name='Bartek' where id=current_setting('test.b')::uuid;
create function pg_temp.b_feed() returns table(actor_name text,recipient_names text[]) language sql as $$
  select actor_name,recipient_names from public.activity_page() where expense_id=current_setting('test.e')::uuid
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(jsonb_build_object('id',current_setting('test.e'),'amount_minor',900,'currency','PLN','category','travel',
 'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',300),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',300),
 jsonb_build_object('user_id',current_setting('test.c'),'amount_minor',300))));
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin
 assert (select actor_name='Anna' and 'Bartek'=any(recipient_names) and 'Anna'=any(recipient_names) from pg_temp.b_feed()),
   'Feed does not name unconnected co-participants';
 assert not exists(select 1 from information_schema.columns where table_schema='public' and table_name='activity_event'
   and column_name in ('actor_name','recipient_name','recipient_names')),'Name copies still stored';
end $$;
select 'ok 1 - the feed resolves every participant name from user IDs' as result;

select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.update_display_name('Ania');
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert (select actor_name='Ania' from pg_temp.b_feed()),'Rename not reflected in history'; end $$;
select 'ok 2 - renames apply to existing history' as result;

-- C deletes their account while sharing A's former name.
reset role;
update public.profile set display_name='Ania' where id=current_setting('test.c')::uuid;
select public.redact_account_data(current_setting('test.c')::uuid);
set local role authenticated;
do $$ begin
 assert (select actor_name='Ania' and recipient_names @> array['Bartek','Deleted user'] and not 'Ania'=any(recipient_names) from pg_temp.b_feed()),
   'Deletion redaction hit the wrong person or cleared the list';
end $$;
reset role;
select 'ok 3 - account deletion redacts only the deleted person' as result;
rollback;
