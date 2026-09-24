-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..10' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.c',gen_random_uuid()::text,true),set_config('test.e',gen_random_uuid()::text,true),
 set_config('test.rule',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'security-a@example.invalid'),
 (current_setting('test.b')::uuid,'security-b@example.invalid'),(current_setting('test.c')::uuid,'security-c@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());
select set_config('test.payload',jsonb_build_object('id',current_setting('test.e'),'amount_minor',1000,'currency','PLN','category','other','spent_at',current_date,
 'paid_by',current_setting('test.a'),'shares',jsonb_build_array(jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',500)))::text,true);

do $$ begin
 assert to_regclass('public.household') is null and to_regclass('public.household_member') is null,'Legacy households remain';
 assert to_regclass('public.v_personal_month_spend') is null,'Unsafe view remains';
 assert not has_table_privilege('anon','public.expense','SELECT'),'Anonymous read grant remains';
 assert not has_table_privilege('authenticated','public.expense_share','UPDATE'),'Client can forge acceptance';
 assert not has_table_privilege('authenticated','public.expense_edit_proposal','UPDATE'),'Client can self-approve';
 assert not has_function_privilege('anon','public.save_expense(jsonb,bigint)','EXECUTE'),'Anonymous RPC exposed';
 assert not has_function_privilege('authenticated','private.validate_expense_payload(uuid,uuid,integer,text,jsonb)','EXECUTE'),'Internal helper exposed';
end $$;
select 'ok 1 - unsafe objects and direct mutation grants are gone' as result;

select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
set local role authenticated;
select public.save_expense(current_setting('test.payload')::jsonb);
set constraints all immediate;
set constraints all deferred;
do $$ declare denied boolean:=false; begin
 assert (select count(*)=2 from public.expense_share where expense_id=current_setting('test.e')::uuid),'Shares missing';
 assert (select status='pending' from public.expense_share where expense_id=current_setting('test.e')::uuid and user_id=current_setting('test.b')::uuid),'Other user auto-accepted';
 assert not exists(select 1 from public.balance_snapshot()),'Unaccepted debt entered balances';
 begin update public.expense_share set status='accepted' where expense_id=current_setting('test.e')::uuid;
 exception when insufficient_privilege then denied:=true; end;
 assert denied,'Creator can bypass consent';
 denied:=false;
 begin update public.expense set amount_minor=2000 where id=current_setting('test.e')::uuid;
 exception when insufficient_privilege then denied:=true; end;
 assert denied,'Direct total update allowed';
end $$;
select 'ok 2 - atomic creation and server-controlled consent' as result;

do $$ declare denied boolean; bad jsonb; before_count bigint; begin
 select count(*) into before_count from public.expense;
 bad:=current_setting('test.payload')::jsonb||jsonb_build_object('id',gen_random_uuid(),'shares',jsonb_build_array(
   jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',0),jsonb_build_object('user_id',current_setting('test.c'),'amount_minor',1000)));
 denied:=false; begin perform public.save_expense(bad); exception when raise_exception then denied:=true; end;
 assert denied,'Unconnected user injection allowed';
 bad:=current_setting('test.payload')::jsonb||jsonb_build_object('id',gen_random_uuid(),'amount_minor',2000);
 denied:=false; begin perform public.save_expense(bad); exception when raise_exception then denied:=true; end;
 assert denied,'Invalid share total allowed';
 assert (select count(*)=before_count from public.expense),'Failed create left orphan expense';
 bad:=current_setting('test.payload')::jsonb||jsonb_build_object('id',gen_random_uuid(),'paid_by',current_setting('test.c'));
 denied:=false; begin perform public.save_expense(bad); exception when raise_exception then denied:=true; end;
 assert denied,'Payer outside participants allowed';
 bad:=current_setting('test.payload')::jsonb||jsonb_build_object('id',gen_random_uuid(),'currency','XXX');
 denied:=false; begin perform public.save_expense(bad); exception when raise_exception then denied:=true; end;
 assert denied,'Unsupported currency allowed';
end $$;
select 'ok 3 - invalid payloads roll back completely' as result;

select set_config('request.jwt.claim.sub',current_setting('test.c'),true);
do $$ declare denied boolean:=false; begin
 assert not exists(select 1 from public.expense where id=current_setting('test.e')::uuid),'Outsider sees expense';
 assert not exists(select 1 from public.expense_share where expense_id=current_setting('test.e')::uuid),'Outsider sees shares';
 assert not exists(select 1 from public.activity_event where expense_id=current_setting('test.e')::uuid),'Outsider sees activity';
 begin perform public.save_expense(current_setting('test.payload')::jsonb,1); exception when raise_exception then denied:=true; end;
 assert denied,'Outsider edited expense';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.respond_to_expense_share(current_setting('test.e')::uuid,'accept_with_trust');
do $$ begin
 assert (select amount_minor=-500 from public.balance_snapshot() where person_id=current_setting('test.a')::uuid),'Accepted balance wrong';
 assert exists(select 1 from public.expense_share_trust where user_id=auth.uid() and trusted_user_id=current_setting('test.a')::uuid),'Directional trust missing';
end $$;
select 'ok 4 - participant visibility, own acceptance and directional trust' as result;

select set_config('test.proposal',public.create_expense_edit_proposal(current_setting('test.e')::uuid,1,current_setting('test.payload')::jsonb)::text,true);
do $$ declare denied boolean:=false; begin
 begin update public.expense_edit_proposal set status='accepted' where id=current_setting('test.proposal')::uuid;
 exception when insufficient_privilege then denied:=true; end;
 assert denied,'Proposer forged approval';
 denied:=false;
 begin perform public.respond_to_edit_proposal(current_setting('test.proposal')::uuid,true); exception when raise_exception then denied:=true; end;
 assert denied,'Proposer approved own proposal via RPC';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.respond_to_edit_proposal(current_setting('test.proposal')::uuid,true);
do $$ declare denied boolean:=false; begin
 assert (select version=2 from public.expense where id=current_setting('test.e')::uuid),'Version not advanced';
 assert (select status='accepted' from public.expense_edit_proposal where id=current_setting('test.proposal')::uuid),'Creator approval failed';
 begin perform public.save_expense(current_setting('test.payload')::jsonb,1); exception when raise_exception then denied:=true; end;
 assert denied,'Stale edit overwrote newer revision';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select set_config('test.proposal',public.create_expense_edit_proposal(current_setting('test.e')::uuid,2,current_setting('test.payload')::jsonb)::text,true);
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(current_setting('test.payload')::jsonb||jsonb_build_object('title','New revision','amount_minor',1200,
 'shares',jsonb_build_array(jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',400),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',800))),2);
do $$ begin
 assert exists(select 1 from public.activity_event where expense_id=current_setting('test.e')::uuid and kind='edited'
   and expense_title='New revision' and expense_total_minor=1200 and affected_share_minor=400),'Activity mixed old split with new total';
 assert exists(select 1 from public.expense_share where expense_id=current_setting('test.e')::uuid and user_id=current_setting('test.b')::uuid
   and status='accepted' and accepted_via_trust),'Explicit user trust not applied to revision';
end $$;
do $$ declare denied boolean:=false; begin
 begin perform public.respond_to_edit_proposal(current_setting('test.proposal')::uuid,true); exception when raise_exception then denied:=true; end;
 assert denied,'Stale proposal overwrote newer revision';
end $$;
select 'ok 5 - immutable proposals, creator approval and stale version rejection' as result;

select public.save_recurring_rule(current_setting('test.payload')::jsonb||jsonb_build_object('id',current_setting('test.rule'),
 'interval_unit','month','interval_count',1,'start_date',current_date,'next_occurrence',current_date));
do $$ declare denied boolean:=false; begin
 assert (select jsonb_array_length(shares)=2 and paid_by=auth.uid() from public.recurring_rule where id=current_setting('test.rule')::uuid),'Recurring template incomplete';
 begin perform public.save_recurring_rule(current_setting('test.payload')::jsonb||jsonb_build_object('id',current_setting('test.rule')),99);
 exception when raise_exception then denied:=true; end;
 assert denied,'Stale rule update allowed';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.c'),true);
do $$ declare denied boolean:=false; begin
 assert not exists(select 1 from public.recurring_rule where id=current_setting('test.rule')::uuid),'Outsider sees template';
 begin perform public.save_expense(current_setting('test.payload')::jsonb||jsonb_build_object('id',gen_random_uuid(),'recurring_id',current_setting('test.rule'),
 'paid_by',auth.uid(),'shares',jsonb_build_array(jsonb_build_object('user_id',auth.uid(),'amount_minor',1000))));
 exception when raise_exception then denied:=true; end;
 assert denied,'Attached another owner recurring rule';
end $$;
select 'ok 6 - independent recurring templates and owner/version checks' as result;

do $$ declare i integer; code text; begin
 for i in 1..10 loop
   select error_code into code from public.preview_connection_code('!');
   assert code='unavailable','Unexpected code lookup response';
 end loop;
 select error_code into code from public.preview_connection_code('!');
 assert code='rate_limited','Invalid attempts escaped limiter';
 select error_code into code from public.redeem_connection_code('!');
 assert code='rate_limited','Redeem bypassed shared limit';
end $$;
reset role;
do $$ begin
 assert (select count(*)=10 from private.connection_code_rate_limit where account_id=current_setting('test.c')::uuid),'Failed lookups were not counted';
end $$;
select 'ok 7 - failed attempts persist and enforce rate limits' as result;

-- All rows share now()'s timestamp. Cursor must still traverse every row.
insert into public.activity_event(audience_user_id,kind,actor_id,actor_name,expense_id,expense_title,category,affected_share_minor,expense_total_minor,currency)
select current_setting('test.a')::uuid,'edited',current_setting('test.a')::uuid,'Test',current_setting('test.e')::uuid,'Test','other',500,1000,'PLN' from generate_series(1,60);
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
set local role authenticated;
do $$ declare cursor_id uuid; first_ids uuid[]; remaining bigint; expected bigint; begin
 select count(*) into expected from public.activity_event;
 select array_agg(id order by occurred_at desc,id desc) into first_ids from public.activity_page();
 cursor_id:=first_ids[array_length(first_ids,1)];
 select count(*) into remaining from public.activity_page(cursor_id);
 assert cardinality(first_ids)+remaining=expected,'Timestamp-tied activity entries lost';
 assert not exists(select 1 from public.activity_page(cursor_id) where id=any(first_ids)),'Activity pages overlap';
end $$;
reset role;
set constraints all immediate;
select 'ok 8 - exact composite activity cursor and deferred integrity checks' as result;

-- Privileged mutations still cannot commit a parent/share mismatch.
do $$ declare denied boolean:=false; begin
 begin
   update public.expense set amount_minor=2000 where id=current_setting('test.e')::uuid;
   set constraints all immediate;
 exception when raise_exception then denied:=true; end;
 assert denied,'Parent amount escaped deferred integrity constraint';
 assert (select amount_minor=1200 from public.expense where id=current_setting('test.e')::uuid),'Rejected parent update was not rolled back';
end $$;
set constraints all deferred;
select 'ok 9 - parent updates cannot bypass split totals' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
set local role authenticated;
select set_config('test.personal',gen_random_uuid()::text,true);
select public.save_expense(current_setting('test.payload')::jsonb||jsonb_build_object('id',current_setting('test.personal'),
 'paid_by',auth.uid(),'shares',jsonb_build_array(jsonb_build_object('user_id',auth.uid(),'amount_minor',1000))));
reset role;
select public.redact_account_data(current_setting('test.b')::uuid);
do $$ begin
 assert exists(select 1 from public.expense where id=current_setting('test.e')::uuid),'Deletion erased shared financial history';
 assert not exists(select 1 from public.expense where id=current_setting('test.personal')::uuid),'Deletion retained personal expense';
 assert (select not is_active from public.recurring_rule where id=current_setting('test.rule')::uuid),'Template with deleted participant is still active';
 assert not exists(select 1 from public.expense_share_trust where user_id=current_setting('test.b')::uuid),'Deletion retained trust';
 assert has_function_privilege('service_role','public.claim_account_deletion_job()','EXECUTE'),'Worker lost permissions';
 assert not has_function_privilege('authenticated','public.redact_account_data(uuid)','EXECUTE'),'Client can redact accounts';
end $$;
set local role authenticated;
do $$ declare denied boolean:=false; begin
 assert not public.current_account_is_active(),'Deleted account is active';
 assert not exists(select 1 from public.expense_share),'Deleted account can still read shares';
 begin perform public.save_expense(current_setting('test.payload')::jsonb); exception when raise_exception then denied:=true; end;
 assert denied,'Deleted account can write using stale JWT';
end $$;
reset role;
set constraints all immediate;
select 'ok 10 - account deletion preserves shared history and closes future access' as result;
rollback;
