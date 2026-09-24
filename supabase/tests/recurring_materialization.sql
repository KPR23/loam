-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..7' as plan;
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
 assert (select failure is not null and failed_at is not null and version=1 from public.recurring_rule where id=current_setting('test.broken')::uuid),'Failure hidden from the owner';
 assert (select failure is null from public.recurring_rule where id=current_setting('test.daily')::uuid),'Healthy rule reported a failure';
 assert exists(select 1 from public.activity_event where kind='shared' and actor_id=current_setting('test.a')::uuid
   and audience_user_id=current_setting('test.b')::uuid and expense_title='Rent'),'Scheduled occurrence missing from activity';
end $$;
select 'ok 3 - the hourly pass isolates failing rules' as result;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert public.materialize_recurring_rules()=0,'Non-owner generated another owner''s rule'; end $$;
reset role;
select 'ok 4 - only the owner''s rules are generated on request' as result;

-- Month-end and leap-day rules stay anchored to their start date.
select set_config('test.monthly',gen_random_uuid()::text,true),set_config('test.leap',gen_random_uuid()::text,true),
 set_config('test.drifted',gen_random_uuid()::text,true);
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_recurring_rule(pg_temp.rule(jsonb_build_object('id',current_setting('test.monthly'),'interval_unit','month',
 'start_date','2027-01-31','next_occurrence','2027-01-31')));
select public.save_recurring_rule(pg_temp.rule(jsonb_build_object('id',current_setting('test.leap'),'interval_unit','year',
 'start_date','2028-02-29','next_occurrence','2028-02-29')));
-- Stored by the old stepping: Jan 31, Feb 28, then Mar 28.
select public.save_recurring_rule(pg_temp.rule(jsonb_build_object('id',current_setting('test.drifted'),'interval_unit','month',
 'start_date','2027-01-31','next_occurrence','2027-03-28')));
reset role;
create function pg_temp.dates(p_rule text) returns date[] language sql as $$
  select array_agg(spent_at order by spent_at) from public.expense where recurring_id=current_setting(p_rule)::uuid
$$;
do $$ begin
 perform private.materialize_recurring_rule(current_setting('test.monthly')::uuid,'2027-05-31');
 assert pg_temp.dates('test.monthly')='{2027-01-31,2027-02-28,2027-03-31,2027-04-30,2027-05-31}','Month-end rule drifted';
 assert (select next_occurrence='2027-06-30' from public.recurring_rule where id=current_setting('test.monthly')::uuid),'Month-end rule advanced off schedule';
 perform private.materialize_recurring_rule(current_setting('test.leap')::uuid,'2032-03-01');
 assert pg_temp.dates('test.leap')='{2028-02-29,2029-02-28,2030-02-28,2031-02-28,2032-02-29}','Leap-day rule drifted';
 perform private.materialize_recurring_rule(current_setting('test.drifted')::uuid,'2027-04-30');
 assert pg_temp.dates('test.drifted')='{2027-03-31,2027-04-30}','Drifted next occurrence was not snapped to the schedule';
end $$;
select 'ok 5 - occurrences are anchored to the start date' as result;

-- The rule and its seed expense are saved together, so the hourly job cannot
-- generate the seed date first and a failed seed leaves no rule behind.
select set_config('test.seeded',gen_random_uuid()::text,true),set_config('test.seed',gen_random_uuid()::text,true),
 set_config('test.unseeded',gen_random_uuid()::text,true);
set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.create_recurring_expense(pg_temp.rule(jsonb_build_object('id',current_setting('test.seeded'),'interval_unit','month',
 'start_date',current_date,'next_occurrence',(current_date+interval '1 month')::date)),
 pg_temp.rule(jsonb_build_object('id',current_setting('test.seed'),'spent_at',current_date)));
do $$ declare failed boolean:=false; begin
 assert (select recurring_id=current_setting('test.seeded')::uuid from public.expense where id=current_setting('test.seed')::uuid),'Seed not linked to its rule';
 assert public.materialize_recurring_rules(current_date)=0 and pg_temp.occurrences('test.seeded')=1,'Seed date generated twice';
 begin
   perform public.create_recurring_expense(pg_temp.rule(jsonb_build_object('id',current_setting('test.unseeded'),'interval_unit','month',
     'start_date',current_date,'next_occurrence',(current_date+interval '1 month')::date)),
     pg_temp.rule(jsonb_build_object('id',gen_random_uuid(),'spent_at',current_date,'amount_minor',999)));
 exception when others then failed:=true; end;
 assert failed and not exists(select 1 from public.recurring_rule where id=current_setting('test.unseeded')::uuid),'Rule saved without its seed';
end $$;
reset role;
select 'ok 6 - a recurring rule is created atomically with its seed' as result;

-- A rule past its end date is no longer selected and rewritten every hour.
select set_config('test.ended',gen_random_uuid()::text,true);
insert into public.recurring_rule(id,owner_user_id,paid_by,shares,amount_minor,currency,category,interval_unit,interval_count,start_date,end_date,next_occurrence)
 values(current_setting('test.ended')::uuid,current_setting('test.a')::uuid,current_setting('test.a')::uuid,
  jsonb_build_array(jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',1000)),
  1000,'PLN','other','week',1,current_date-14,current_date-10,current_date-7);
do $$ begin
 perform private.materialize_due_recurring_rules();
 assert (select version=1 from public.recurring_rule where id=current_setting('test.ended')::uuid),'Ended rule was rewritten';
 assert pg_temp.occurrences('test.ended')=0,'Ended rule generated past its end date';
end $$;
select 'ok 7 - ended rules are left alone' as result;
rollback;
