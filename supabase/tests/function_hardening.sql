-- TAP-compatible, rollback-only integration tests. Use supabase test db.
begin;
set local plpgsql.check_asserts=on;
select '1..4' as plan;

do $$ declare bad text; begin
 select string_agg(p.oid::regprocedure::text,', ') into bad
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname in ('public','private') and p.prosecdef
   and not exists(select 1 from unnest(coalesce(p.proconfig,'{}')) c
     where c like 'search_path=%' and c not ilike '%public%' and c not ilike '%$user%');
 assert bad is null,'SECURITY DEFINER functions without a pinned search path: '||bad;
end $$;
select 'ok 1 - privileged functions resolve names without the public schema' as result;

select set_config('test.a',gen_random_uuid()::text,true),set_config('test.b',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('test.a')::uuid,'hardening-a@example.invalid'),
 (current_setting('test.b')::uuid,'hardening-b@example.invalid');
insert into public.repayment(from_user,to_user,amount_minor,currency,paid_at,operation_id)
 values(current_setting('test.a')::uuid,current_setting('test.b')::uuid,100,'PLN',current_date,gen_random_uuid());
select set_config('request.jwt.claim.sub',current_setting('test.a'),true);
set local role authenticated;
do $$ begin
 assert (select count(*)=1 from public.balance_history(current_setting('test.b')::uuid)),'Active account cannot read history';
end $$;
reset role;
update public.profile set deleted_at=now() where id=current_setting('test.a')::uuid;
set local role authenticated;
do $$ begin
 assert not exists(select 1 from public.balance_history(current_setting('test.b')::uuid)),'Closed account can read history';
end $$;
reset role;
select 'ok 2 - balance history requires an active account' as result;

-- New functions are executable by PUBLIC unless revoked, even in private.
do $$ declare bad text; begin
 select string_agg(p.oid::regprocedure::text,', ') into bad
 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='private' and (has_function_privilege('anon',p.oid,'EXECUTE')
   or (has_function_privilege('authenticated',p.oid,'EXECUTE') and p.proname not in ('can_read_expense_shares','are_connected')));
 assert bad is null,'Private functions executable by clients: '||bad;
end $$;
select 'ok 3 - only policy helpers in private are executable by clients' as result;

-- PUBLIC's EXECUTE reaches anon too, so every new public function needs an explicit revoke.
do $$ declare bad text; begin
 select string_agg(p.oid::regprocedure::text,', ') into bad
 from pg_proc p where p.pronamespace='public'::regnamespace
   and has_function_privilege('anon',p.oid,'EXECUTE') and p.proname<>'join_waitlist';
 assert bad is null,'Public functions executable without signing in: '||bad;
end $$;
select 'ok 4 - only the waitlist is callable without signing in' as result;
rollback;
