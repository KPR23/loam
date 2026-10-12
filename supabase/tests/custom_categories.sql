-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..6' as plan;
select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true),
 set_config('test.c',gen_random_uuid()::text,true),set_config('test.cat',gen_random_uuid()::text,true),
 set_config('test.e',gen_random_uuid()::text,true),set_config('test.rule',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'custom-a@example.invalid'),
 (current_setting('test.b')::uuid,'custom-b@example.invalid'),(current_setting('test.c')::uuid,'custom-c@example.invalid');
insert into public.user_connection(user_a,user_b,created_by,accepted_at)
 values(least(current_setting('test.a')::uuid,current_setting('test.b')::uuid),greatest(current_setting('test.a')::uuid,current_setting('test.b')::uuid),current_setting('test.a')::uuid,now());
-- A paid 900, split with B. Callers override fields.
create function pg_temp.expense(p_changes jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object('id',current_setting('test.e'),'amount_minor',900,'currency','PLN','category','other',
    'spent_at',current_date,'paid_by',current_setting('test.a'),'custom_category_id',current_setting('test.cat'),'shares',jsonb_build_array(
    jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',450),jsonb_build_object('user_id',current_setting('test.b'),'amount_minor',450)))||p_changes
$$;
create function pg_temp.custom_id() returns uuid language sql as $$
  select custom_category_id from public.expense where id=current_setting('test.e')::uuid
$$;

set local role authenticated;
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
do $$ declare denied boolean:=false; begin
 begin perform public.save_custom_category(current_setting('test.cat')::uuid,'Pets','pawprint.fill','9C7A55');
 exception when others then denied:=true; end;
 assert denied,'A free account created a category';
end $$;
reset role;
select public.record_pro_entitlement(current_setting('test.a')::uuid,true,null);
set local role authenticated;
select public.save_custom_category(current_setting('test.cat')::uuid,' Pets ','pawprint.fill','9c7a55');
do $$ begin
 assert (select name='Pets' and color_hex='9C7A55' from public.custom_category where id=current_setting('test.cat')::uuid),'Category not normalized';
end $$;
select 'ok 1 - only Pro members add categories' as result;

select public.save_expense(pg_temp.expense());
do $$ begin assert pg_temp.custom_id()=current_setting('test.cat')::uuid,'Custom category not saved'; end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin
 assert (select name='Pets' from public.custom_category where id=current_setting('test.cat')::uuid),'A participant cannot see the category';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.c'),true);
do $$ begin assert not exists(select 1 from public.custom_category),'A stranger can see the category'; end $$;
select 'ok 2 - everyone on the expense sees its custom category' as result;

select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
-- Leaving the key out keeps it; a built-in category drops it.
select public.save_expense(pg_temp.expense()-'custom_category_id'||'{"title":"Vet"}',(select version from public.expense where id=current_setting('test.e')::uuid));
do $$ begin assert pg_temp.custom_id()=current_setting('test.cat')::uuid,'An older client cleared the category'; end $$;
select public.save_expense(pg_temp.expense()-'custom_category_id'||'{"category":"health"}',(select version from public.expense where id=current_setting('test.e')::uuid));
do $$ begin assert pg_temp.custom_id() is null,'A built-in category kept the custom one'; end $$;
do $$ declare denied boolean:=false; begin
 begin perform public.save_expense(pg_temp.expense('{"category":"dining"}'),(select version from public.expense where id=current_setting('test.e')::uuid));
 exception when others then denied:=true; end;
 assert denied,'A custom category was filed under a built-in one';
end $$;
select 'ok 3 - custom categories stay filed under Other' as result;

select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ declare denied boolean:=false; begin
 begin perform public.save_expense(pg_temp.expense(jsonb_build_object('id',gen_random_uuid(),'paid_by',current_setting('test.b'))));
 exception when others then denied:=true; end;
 assert denied,'Someone used another member''s category';
end $$;
select 'ok 4 - only the owner files expenses under a category' as result;

select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
select public.save_recurring_rule(jsonb_build_object('id',current_setting('test.rule'),'amount_minor',100,'currency','PLN','category','other',
 'custom_category_id',current_setting('test.cat'),'paid_by',current_setting('test.a'),'shares',jsonb_build_array(jsonb_build_object('user_id',current_setting('test.a'),'amount_minor',100)),
 'interval_unit','day','interval_count',1,'start_date',current_date-1,'next_occurrence',current_date-1));
select public.materialize_recurring_rules(current_date);
do $$ begin
 assert (select bool_and(custom_category_id=current_setting('test.cat')::uuid) from public.expense where recurring_id=current_setting('test.rule')::uuid),'Occurrences lost the rule''s category';
end $$;
select public.delete_custom_category(current_setting('test.cat')::uuid);
do $$ begin
 assert not exists(select 1 from public.expense where custom_category_id is not null),'Deleting left expenses in the category';
 assert (select bool_and(category='other') from public.expense where recurring_id=current_setting('test.rule')::uuid),'Deleted category''s expenses not under Other';
end $$;
select 'ok 5 - recurring expenses keep the category, and deleting one files them under Other' as result;

select public.set_hidden_categories(array['dining','other']::public.expense_category[]);
do $$ begin
 assert (select array_agg(category)=array['dining']::public.expense_category[] from public.hidden_category),'Hidden categories not saved, or Other hidden';
end $$;
select set_config('request.jwt.claim.sub',current_setting('test.b'),true);
do $$ begin assert not exists(select 1 from public.hidden_category),'Another member''s hidden categories are visible'; end $$;
reset role;
do $$ begin
 assert not has_function_privilege('anon','public.save_custom_category(uuid,text,text,text)','EXECUTE'),'Anonymous users can add categories';
 assert not has_table_privilege('authenticated','public.custom_category','INSERT'),'Clients can write categories directly';
end $$;
select 'ok 6 - hidden categories are private, and writes go through the RPCs' as result;
rollback;
