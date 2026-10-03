-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..2' as plan;

set local role anon;
select public.join_waitlist('  Someone@Example.com ','x');
select public.join_waitlist('someone@example.com');
do $$ declare denied boolean:=false; begin
 begin perform public.join_waitlist('not-an-email');
 exception when invalid_parameter_value then denied:=true; end;
 assert denied,'Invalid email accepted';
end $$;
reset role;
do $$ begin
 assert not has_table_privilege('anon','private.waitlist_signup','SELECT'),'anon can read the waitlist';
end $$;
select 'ok 1 - anon can join but not read the waitlist' as result;

do $$ begin
 assert (select count(*) from private.waitlist_signup where email='someone@example.com')=1,'Duplicate or unnormalized signup';
 assert (select source from private.waitlist_signup where email='someone@example.com')='x','First signup was overwritten';
end $$;
select 'ok 2 - signups are normalized and deduplicated' as result;
rollback;
