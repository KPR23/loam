-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..5' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'push-a@example.invalid'),
 (current_setting('test.b')::uuid,'push-b@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 select least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),
 current_setting('test.a')::uuid,now();

-- Devices belong to the signed-in account and move with the phone.
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.register_push_device(repeat('ab',32),'sandbox');
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.register_push_device(upper(repeat('ab',32)),'sandbox');
reset role;
do $$ begin
 assert (select user_id from private.push_device where token=repeat('ab',32))=current_setting('test.b')::uuid,'Token did not move to the new account';
 assert (select count(*) from private.push_device)=1,'Token duplicated';
end $$;
set local role authenticated;
select public.unregister_push_device(repeat('ab',32));
reset role;
do $$ begin assert (select count(*) from private.push_device)=0,'Own token not removed'; end $$;
select public.register_push_device(repeat('cd',32),'production');
do $$ declare denied boolean:=false; begin
 begin perform public.register_push_device('not-hex!','sandbox'); exception when invalid_parameter_value then denied:=true; end;
 assert denied,'Malformed token accepted';
end $$;
select 'ok 1 - devices follow the signed-in account' as result;

-- Another account cannot remove a device it does not own.
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
set local role authenticated;
select public.unregister_push_device(repeat('cd',32));
reset role;
do $$ begin assert (select count(*) from private.push_device)=1,'Foreign token removed'; end $$;
select 'ok 2 - unregister only touches own devices' as result;

-- B has a device; A shares an expense with B.
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(jsonb_build_object('id',current_setting('test.e'),'amount_minor',900,'currency','PLN','category','dining',
 'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',450),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',450))));
reset role;
insert into private.push_device(token,user_id,environment) values(repeat('ef',32),current_setting('test.b')::uuid,'sandbox');
do $$ declare e uuid; begin
 select id into e from public.activity_event where audience_user_id=current_setting('test.b')::uuid and kind='shared';
 assert e is not null,'Shared event missing';
 assert (select count(*) from public.push_event_context(e))=1,'Unread event has no push context';
 assert (select badge from public.push_event_context(e))=1,'Badge is not the unread count';
 assert (select jsonb_array_length(devices) from public.push_event_context(e))=2,'Devices missing';
 -- The actor's own event is never pushed.
 assert not exists(select 1 from public.activity_event a, lateral public.push_event_context(a.id) c where a.audience_user_id=current_setting('test.a')::uuid),'Own action pushed';
 -- Muting the category suppresses it.
 insert into private.notification_preference(user_id,requests) values(current_setting('test.b')::uuid,false);
 assert (select count(*) from public.push_event_context(e))=0,'Muted category still pushed';
 update private.notification_preference set requests=true;
 -- A read event is not pushed.
 update public.activity_event set read_at=now() where id=e;
 assert (select count(*) from public.push_event_context(e))=0,'Read event pushed';
end $$;
select 'ok 3 - push context honours read state, own actions and mutes' as result;

do $$ begin
 assert not has_function_privilege('authenticated','public.push_event_context(uuid)','EXECUTE'),'Clients can read push context';
 assert not has_function_privilege('authenticated','public.remove_push_devices(text[])','EXECUTE'),'Clients can drop devices';
 assert not has_table_privilege('authenticated','private.push_device','SELECT'),'Clients can read tokens';
 assert has_function_privilege('service_role','public.push_event_context(uuid)','EXECUTE'),'Sender cannot read push context';
end $$;
select 'ok 4 - only the sender can read push context' as result;

-- Deleting an account soft-deletes auth.users, so cleanup must remove these itself.
insert into private.notification_preference(user_id,requests) values(current_setting('test.b')::uuid,false)
 on conflict(user_id) do update set requests=false;
select public.redact_account_data(current_setting('test.b')::uuid);
do $$ begin
 assert not exists(select 1 from private.push_device where user_id=current_setting('test.b')::uuid),'Deleted account keeps device tokens';
 assert not exists(select 1 from private.notification_preference where user_id=current_setting('test.b')::uuid),'Deleted account keeps notification choices';
end $$;
select 'ok 5 - account deletion removes devices and notification choices' as result;
rollback;
