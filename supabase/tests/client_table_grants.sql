-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..2' as plan;
select set_config('test.a',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'grants-a@example.invalid');

do $$ declare t text; p text; begin
 foreach t in array array['profile','repayment','user_connection','connection_invitation'] loop
   foreach p in array array['INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES'] loop
     assert not has_table_privilege('authenticated','public.'||t,p),format('authenticated has %s on %s',p,t);
   end loop;
   assert has_table_privilege('authenticated','public.'||t,'SELECT'),format('authenticated cannot read %s',t);
 end loop;
 assert has_column_privilege('authenticated','public.profile','avatar_path','UPDATE'),'Avatar pointer not writable';
 assert not has_column_privilege('authenticated','public.profile','display_name','UPDATE'),'Display name bypasses RPC validation';
 assert not has_column_privilege('authenticated','public.profile','deleted_at','UPDATE'),'Deletion marker writable';
end $$;
select 'ok 1 - clients can only read tables and write their avatar pointer' as result;

select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
set local role authenticated;
do $$ declare denied boolean:=false; begin
 update public.profile set avatar_path=auth.uid()||'/'||gen_random_uuid()||'.jpg' where id=auth.uid();
 assert found,'Own avatar pointer update failed';
 begin update public.profile set avatar_path=gen_random_uuid()||'/'||gen_random_uuid()||'.jpg' where id=auth.uid();
 exception when check_violation then denied:=true; end;
 assert denied,'Avatar pointer can reference another folder';
 denied:=false;
 begin update public.profile set display_name=repeat('x',1000) where id=auth.uid();
 exception when insufficient_privilege then denied:=true; end;
 assert denied,'Direct display name write allowed';
end $$;
reset role;
select 'ok 2 - avatar pointers stay inside the owner folder' as result;
rollback;
