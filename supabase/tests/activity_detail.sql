-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..4' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.c',gen_random_uuid()::text,true),set_config('test.e',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'detail-a@example.invalid'),
 (current_setting('test.b')::uuid,'detail-b@example.invalid'),(current_setting('test.c')::uuid,'detail-c@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 select least(current_setting('test.a')::uuid,u),greatest(current_setting('test.a')::uuid,u),current_setting('test.a')::uuid,now()
 from unnest(array[current_setting('test.b')::uuid,current_setting('test.c')::uuid]) u;
-- One transaction shares a timestamp, so compare kinds as sorted sets.
-- A paid 900, split three ways. Callers override fields.
create function pg_temp.expense(p_changes jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('id',current_setting('test.e'),'amount_minor',900,'currency','PLN','category','dining',
    'spent_at',current_date,'paid_by',current_setting('test.a'),'shares',jsonb_build_array(
    jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',300),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',300),
    jsonb_build_object('user_id',current_setting('test.c'),'amount_minor',300)))||p_changes
$$;
create function pg_temp.version() returns bigint language sql as $$ select version from public.expense where id=current_setting('test.e')::uuid $$;
create function pg_temp.kinds() returns text[] language sql as $$
  select coalesce(array_agg(kind order by kind),'{}') from public.expense_activity(current_setting('test.e')::uuid)
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_expense(pg_temp.expense());
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin
 assert (select current_setting('test.b')::uuid=any(recipient_ids) and cardinality(recipient_ids)=cardinality(recipient_names)
   from public.activity_page() where expense_id=current_setting('test.e')::uuid and kind='shared'),'Feed lacks recipient IDs';
end $$;
select 'ok 1 - the feed returns recipient IDs next to their names' as result;

select set_config('test.proposal',public.create_expense_edit_proposal(current_setting('test.e')::uuid,pg_temp.version(),
 pg_temp.expense(jsonb_build_object('amount_minor',1200,'shares',jsonb_build_array(
 jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',300),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',600),
 jsonb_build_object('user_id',current_setting('test.c'),'amount_minor',300)))))::text,true);
do $$ begin assert pg_temp.kinds()=array['proposal_created','shared'],'Proposer cannot see their proposal in the history'; end $$;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.respond_to_edit_proposal(current_setting('test.proposal')::uuid,true);
do $$ begin
 assert pg_temp.kinds()=array['proposal_accepted','proposal_created','shared'],'Owner sees a duplicate edit event';
 assert (select recipient_id=current_setting('test.b')::uuid from public.expense_activity(current_setting('test.e')::uuid)
   where kind='proposal_accepted'),'Accepted proposal does not name the proposer';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert pg_temp.kinds()=array['proposal_accepted','proposal_created','shared'],'Proposer sees a duplicate edit event'; end $$;
select set_config('request.jwt.claim.sub',current_setting('test.c'),true);
do $$ begin assert pg_temp.kinds()=array['edited','shared'],'Other participants miss the applied edit'; end $$;
select 'ok 2 - an applied proposal is one event naming the proposer' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select set_config('test.repayment',public.create_repayment(current_setting('test.a')::uuid,200,'PLN','Cash',current_date,gen_random_uuid())::text,true);
do $$ begin
 assert (select kind='repayment_recorded' and actor_id=current_setting('test.b')::uuid and recipient_id=current_setting('test.a')::uuid
   and affected_share_minor=200 and expense_title='Cash' and repayment_id=current_setting('test.repayment')::uuid
   from public.activity_page() where repayment_id is not null),'Payer has no repayment event';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ begin
 assert (select count(*)=1 from public.activity_page() where kind='repayment_recorded'),'Recipient has no repayment event';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.c'),true);
do $$ begin assert not exists(select 1 from public.activity_page() where repayment_id is not null),'Repayment leaked to a third person'; end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
select public.reverse_repayment(current_setting('test.repayment')::uuid,gen_random_uuid());
do $$ begin
 assert (select count(*)=1 from public.activity_page() where kind='repayment_reversed'),'Reversal not recorded';
end $$;
select 'ok 3 - repayments and reversals are recorded for both people' as result;

select set_config('request.jwt.claim.sub',current_setting('test.c'),true);
do $$ begin
 assert not has_function_privilege('anon','public.expense_activity(uuid)','EXECUTE'),'Anonymous users can read expense history';
 assert not exists(select 1 from public.expense_activity(gen_random_uuid())),'Unknown expense returned history';
end $$;
reset role;
do $$ begin
 assert not has_function_privilege('authenticated','private.log_repayment_activity()','EXECUTE'),'Clients can forge repayment events';
 assert not has_function_privilege('authenticated','private.log_expense_event(text,public.expense,jsonb,uuid,uuid[],uuid)','EXECUTE'),'Clients can forge expense events';
end $$;
select 'ok 4 - history is limited to the caller and logging stays private' as result;
rollback;
