-- Loam audit reproductions, 2026-09-23.
-- Diagnostic script, not a migration or a passing regression suite.
-- Requires an administrator SQL session in a disposable development project.
-- Each transaction is rolled back; do not replace ROLLBACK with COMMIT.

begin read only;
set local role anon;
select current_user as role, auth.uid() is null as signed_out,
       (select count(*) from public.v_personal_month_spend) as monthly_summary_rows_visible;
rollback;

-- Audit proof: synthetic users and rows; all writes are rolled back.
begin;
select set_config('audit.a',gen_random_uuid()::text,true),
       set_config('audit.b',gen_random_uuid()::text,true),
       set_config('audit.c',gen_random_uuid()::text,true),
       set_config('audit.h',gen_random_uuid()::text,true),
       set_config('audit.e',gen_random_uuid()::text,true),
       set_config('audit.personal',gen_random_uuid()::text,true),
       set_config('audit.proposal',gen_random_uuid()::text,true);
insert into auth.users(id,email) values
 (current_setting('audit.a')::uuid,'audit-a@example.invalid'),
 (current_setting('audit.b')::uuid,'audit-b@example.invalid'),
 (current_setting('audit.c')::uuid,'audit-c@example.invalid');
insert into public.household(id,name,created_by)
values(current_setting('audit.h')::uuid,'Audit fixture',current_setting('audit.a')::uuid);
insert into public.household_member(household_id,user_id,display_name,role) values
 (current_setting('audit.h')::uuid,current_setting('audit.a')::uuid,'Audit A','owner'),
 (current_setting('audit.h')::uuid,current_setting('audit.b')::uuid,'Audit B','member');
insert into public.expense(id,amount_minor,paid_by,created_by,household_id)
values(current_setting('audit.e')::uuid,1000,current_setting('audit.a')::uuid,current_setting('audit.a')::uuid,current_setting('audit.h')::uuid);
insert into public.expense_share(expense_id,user_id,amount_minor) values
 (current_setting('audit.e')::uuid,current_setting('audit.a')::uuid,500),
 (current_setting('audit.e')::uuid,current_setting('audit.b')::uuid,500);
set constraints all immediate;

-- Authenticated outsider C self-joins an unrelated household as owner.
select set_config('request.jwt.claim.sub',current_setting('audit.c'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('audit.c'),'role','authenticated')::text,true);
set local role authenticated;
insert into public.household_member(household_id,user_id,display_name,role)
values(current_setting('audit.h')::uuid,current_setting('audit.c')::uuid,'Audit outsider','owner');
select set_config('audit.outsider_became_owner',public.is_household_owner(current_setting('audit.h')::uuid)::text,true);

-- Creator A can accept B's share through a direct UPDATE.
select set_config('request.jwt.claim.sub',current_setting('audit.a'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('audit.a'),'role','authenticated')::text,true);
update public.expense_share set status='accepted'
where expense_id=current_setting('audit.e')::uuid and user_id=current_setting('audit.b')::uuid;
select set_config('audit.creator_accepted_other_share',(select (status='accepted')::text from public.expense_share where expense_id=current_setting('audit.e')::uuid and user_id=current_setting('audit.b')::uuid),true);

-- Updating the expense alone escapes the share-sum constraint trigger.
update public.expense set amount_minor=2000 where id=current_setting('audit.e')::uuid;
select set_config('audit.mismatched_total_allowed',(select (e.amount_minor <> (select sum(s.amount_minor) from public.expense_share s where s.expense_id=e.id))::text from public.expense e where e.id=current_setting('audit.e')::uuid),true);
update public.expense set amount_minor=1000 where id=current_setting('audit.e')::uuid;

-- A can attach a different user's share to a "personal" expense;
-- the insert trigger accepts it automatically, without trust or connection.
insert into public.expense(id,amount_minor,paid_by,created_by,household_id)
values(current_setting('audit.personal')::uuid,1000,current_setting('audit.a')::uuid,current_setting('audit.a')::uuid,null);
insert into public.expense_share(expense_id,user_id,amount_minor) values
 (current_setting('audit.personal')::uuid,current_setting('audit.a')::uuid,0),
 (current_setting('audit.personal')::uuid,current_setting('audit.b')::uuid,1000);
select set_config('audit.personal_other_share_accepted',(select (status='accepted')::text from public.expense_share where expense_id=current_setting('audit.personal')::uuid and user_id=current_setting('audit.b')::uuid),true);
select set_config('audit.unconnected_debt',(select amount_minor::text from public.balance_snapshot() where person_id=current_setting('audit.b')::uuid and currency='PLN'),true);

-- B can bypass the proposal RPC and mark their own proposal accepted.
select set_config('request.jwt.claim.sub',current_setting('audit.b'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('audit.b'),'role','authenticated')::text,true);
insert into public.expense_edit_proposal(id,expense_id,proposed_by,amount_minor,category,spent_at,paid_by,shares)
values(current_setting('audit.proposal')::uuid,current_setting('audit.e')::uuid,current_setting('audit.b')::uuid,1000,'other',current_date,current_setting('audit.a')::uuid,
 jsonb_build_array(jsonb_build_object('user_id',current_setting('audit.a'),'amount_minor',500),jsonb_build_object('user_id',current_setting('audit.b'),'amount_minor',500)));
update public.expense_edit_proposal set status='accepted' where id=current_setting('audit.proposal')::uuid;
select set_config('audit.proposer_self_accepted',(select (status='accepted')::text from public.expense_edit_proposal where id=current_setting('audit.proposal')::uuid),true);

set constraints all immediate;
select jsonb_build_object(
 'outsider_became_household_owner',current_setting('audit.outsider_became_owner')::boolean,
 'creator_accepted_other_users_share',current_setting('audit.creator_accepted_other_share')::boolean,
 'expense_total_mismatch_allowed',current_setting('audit.mismatched_total_allowed')::boolean,
 'personal_expense_forced_other_user_acceptance',current_setting('audit.personal_other_share_accepted')::boolean,
 'unconnected_debt_minor',current_setting('audit.unconnected_debt')::integer,
 'proposer_marked_own_proposal_accepted',current_setting('audit.proposer_self_accepted')::boolean
) as audit_proof;
rollback;


-- Failed connection-code attempts are rolled back before they can be counted.
begin;
select set_config('audit.rate_user',gen_random_uuid()::text,true);
insert into auth.users(id,email) values(current_setting('audit.rate_user')::uuid,'audit-rate@example.invalid');
select set_config('request.jwt.claim.sub',current_setting('audit.rate_user'),true),
 set_config('request.jwt.claims',jsonb_build_object('sub',current_setting('audit.rate_user'),'role','authenticated')::text,true);
set local role authenticated;
do $audit$
declare i integer; unavailable integer := 0; limited integer := 0;
begin
 for i in 1..12 loop
  begin
   perform public.preview_connection_code('!');
  exception when others then
   if sqlerrm = 'That code is unavailable.' then unavailable:=unavailable+1;
   elsif sqlerrm = 'Too many attempts. Please try again later.' then limited:=limited+1;
   else raise; end if;
  end;
 end loop;
 perform set_config('audit.invalid_attempts',unavailable::text,true);
 perform set_config('audit.limited_attempts',limited::text,true);
end
$audit$;
reset role;
select current_setting('audit.invalid_attempts')::integer as invalid_attempts,
 current_setting('audit.limited_attempts')::integer as attempts_rate_limited,
 (select count(*) from public.connection_code_rate_limit where account_id=current_setting('audit.rate_user')::uuid) as persisted_rate_counter_rows;
rollback;

