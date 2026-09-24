-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..4' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.c',gen_random_uuid()::text,true),set_config('test.weekly',gen_random_uuid()::text,true),
 set_config('test.daily',gen_random_uuid()::text,true),set_config('test.broken',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'recurring-a@example.invalid'),
 (current_setting('test.b')::uuid,'recurring-b@example.invalid'),(current_setting('test.c')::uuid,'recurring-c@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());
-- Rule fixture owned by A: 1000 split A 400 / B 600, paid by A. Callers override fields.
create function pg_temp.rule(p_changes jsonb) returns jsonb language sql as $$
  select jsonb_build_object('amount_minor',1000,'currency','PLN','category','housing','title','Rent','paid_by',current_setting('test.a'),
    'shares',jsonb_build_array(jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',400),
      jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',600)),'interval_count',1)||p_changes
$$;
create function pg_temp.occurrences(p_rule text) returns bigint language sql as $$
  select count(*) from public.expense where recurring_id=current_setting(p_rule)::uuid
$$;

do $$ begin
 assert has_function_privilege('authenticated','public.materialize_recurring_rules(date)','EXECUTE'),'Owner cannot trigger generation';
 assert not has_function_privilege('authenticated','private.materialize_recurring_rule(uuid,date)','EXECUTE'),'Rule internals exposed';
 assert not has_function_privilege('authenticated','private.materialize_due_recurring_rules()','EXECUTE'),'Global generation exposed';
 assert exists(select 1 from cron.job where jobname='loam-recurring-materializer' and command like '%materialize_due_recurring_rules%'),'Hourly job missing';
end $$;
select 'ok 1 - generation is callable by owners and scheduled hourly' as result;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_recurring_rule(pg_temp.rule(jsonb_build_object('id',current_setting('test.weekly'),'interval_unit','week',
 'start_date',current_date-20,'next_occurrence',current_date-20,'skipped_dates',jsonb_build_array(current_date-13))));
do $$ declare denied boolean:=false; begin
 assert public.materialize_recurring_rules(current_date)=2,'Due weekly occurrences not created';
 assert pg_temp.occurrences('test.weekly')=2,'Skipped date was generated';
 assert (select next_occurrence=current_date+1 from public.recurring_rule where id=current_setting('test.weekly')::uuid),'Rule not advanced';
 assert (select bool_and(s.status='pending' and e.title='Rent' and e.paid_by=auth.uid()) from public.expense e join public.expense_share s on s.expense_id=e.id
   where e.recurring_id=current_setting('test.weekly')::uuid and s.user_id=current_setting('test.b')::uuid),'Occurrence ignored the rule template or consent';
 assert public.materialize_recurring_rules(current_date)=0,'Second pass duplicated occurrences';
 begin perform public.materialize_recurring_rules(current_date+30); exception when raise_exception then denied:=true; end;
 assert denied,'Client generated future occurrences';
end $$;
select 'ok 2 - owners generate due occurrences from the rule exactly once' as result;

-- A rule whose participant can no longer be split with must not block others.
reset role;
insert into public.recurring_rule(id,owner_user_id,paid_by,shares,amount_minor,currency,category,interval_unit,interval_count,start_date,next_occurrence)
 values(current_setting('test.broken')::uuid,current_setting('test.a')::uuid,current_setting('test.a')::uuid,
  jsonb_build_array(jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('test.c'),'amount_minor',500)),
  1000,'PLN','other','day',1,current_date,current_date);
set local role authenticated;
select public.save_recurring_rule(pg_temp.rule(jsonb_build_object('id',current_setting('test.daily'),'interval_unit','day',
 'start_date',current_date-1,'next_occurrence',current_date-1)));
reset role;
select set_config('request.jwt.claim.sub','',true);
do $$ begin
 assert private.materialize_due_recurring_rules()=2,'Scheduled pass skipped a healthy rule';
 assert pg_temp.occurrences('test.broken')=0,'Invalid template was generated';
 assert (select next_occurrence=current_date from public.recurring_rule where id=current_setting('test.broken')::uuid),'Failed rule advanced past a missed date';
 assert exists(select 1 from public.activity_event where kind='shared' and actor_id=current_setting('test.a')::uuid
   and audience_user_id=current_setting('test.b')::uuid and expense_title='Rent'),'Scheduled occurrence missing from activity';
end $$;
select 'ok 3 - the hourly pass isolates failing rules' as result;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert public.materialize_recurring_rules()=0,'Non-owner generated another owner''s rule'; end $$;
reset role;
select 'ok 4 - only the owner''s rules are generated on request' as result;
rollback;
