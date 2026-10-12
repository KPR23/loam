-- Loam Pro members can add their own categories and hide built-in ones.
-- An expense in a custom category is still filed under 'other', so older app
-- versions, activity and balance history keep working; the custom category
-- rides along as custom_category_id, and everyone on the expense sees its
-- name, icon and color.

create table public.custom_category(
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null check(char_length(btrim(name)) between 1 and 24),
  symbol text not null check(symbol ~ '^[a-z0-9.]{1,64}$'),
  color_hex text not null check(color_hex ~ '^[0-9A-F]{6}$'),
  created_at timestamptz not null default now()
);
create index custom_category_owner_idx on public.custom_category(owner_id);
alter table public.custom_category enable row level security;
revoke all on public.custom_category from public,anon,authenticated;
grant select on public.custom_category to authenticated;

-- Deleting a category files its expenses back under Other.
alter table public.expense add column custom_category_id uuid references public.custom_category(id) on delete set null;
alter table public.recurring_rule add column custom_category_id uuid references public.custom_category(id) on delete set null;
create index expense_custom_category_idx on public.expense(custom_category_id) where custom_category_id is not null;
create index recurring_rule_custom_category_idx on public.recurring_rule(custom_category_id) where custom_category_id is not null;

-- The owner sees all of theirs; others see the ones on expenses they can read.
create policy custom_category_read on public.custom_category for select to authenticated using (
  (select public.current_account_is_active()) and (owner_id=(select auth.uid())
    or exists(select 1 from public.expense e where e.custom_category_id=custom_category.id)));

-- Built-in categories a member removed from their picker. Their expenses keep them.
create table public.hidden_category(
  user_id uuid not null references auth.users(id) on delete cascade,
  category public.expense_category not null check(category<>'other'),
  primary key(user_id,category)
);
alter table public.hidden_category enable row level security;
revoke all on public.hidden_category from public,anon,authenticated;
grant select on public.hidden_category to authenticated;
create policy hidden_category_read on public.hidden_category for select to authenticated using (user_id=(select auth.uid()));

-- Picking a built-in category drops the custom one, whichever path saved it
-- (an edit, an accepted proposal). A new recurring occurrence takes its rule's.
create function private.keep_expense_custom_category() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.category<>'other' then
    new.custom_category_id:=null;
  elsif tg_op='INSERT' and new.custom_category_id is null and new.recurring_id is not null then
    select r.custom_category_id into new.custom_category_id from public.recurring_rule r where r.id=new.recurring_id;
  end if;
  return new;
end $$;
revoke all on function private.keep_expense_custom_category() from public,anon,authenticated;
create trigger expense_custom_category before insert or update on public.expense
  for each row execute function private.keep_expense_custom_category();

create function private.keep_rule_custom_category() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.category<>'other' then new.custom_category_id:=null; end if;
  return new;
end $$;
revoke all on function private.keep_rule_custom_category() from public,anon,authenticated;
create trigger recurring_rule_custom_category before insert or update on public.recurring_rule
  for each row execute function private.keep_rule_custom_category();

-- Sets the custom category from a saved payload. A payload without the key
-- (an older app version) keeps the current one.
create function private.apply_custom_category(p_uid uuid,p_payload jsonb,p_expense_id uuid,p_rule_id uuid) returns void
language plpgsql set search_path='' as $$
declare v_id uuid;
begin
  if not (p_payload ? 'custom_category_id') then return; end if;
  v_id:=(p_payload->>'custom_category_id')::uuid;
  if v_id is not null then
    if not exists(select 1 from public.custom_category where id=v_id and owner_id=p_uid) then raise exception 'Category not found'; end if;
    if p_payload->>'category' is distinct from 'other' then raise exception 'Custom categories are filed under Other'; end if;
  end if;
  if p_expense_id is not null then
    update public.expense set custom_category_id=v_id where id=p_expense_id and custom_category_id is distinct from v_id;
  end if;
  if p_rule_id is not null then
    update public.recurring_rule set custom_category_id=v_id where id=p_rule_id and custom_category_id is distinct from v_id;
  end if;
end $$;
revoke all on function private.apply_custom_category(uuid,jsonb,uuid,uuid) from public,anon,authenticated;

create or replace function public.save_expense(p_expense jsonb,p_expected_version bigint default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  v_id:=private.save_expense_as(auth.uid(),p_expense,p_expected_version);
  perform private.apply_custom_category(auth.uid(),p_expense,v_id,null);
  return v_id;
end $$;

-- Same as before, plus the custom category.
create or replace function public.save_recurring_rule(p_rule jsonb,p_expected_version bigint default null) returns uuid
language plpgsql security definer set search_path='' as $$
declare r public.recurring_rule; v_id uuid:=(p_rule->>'id')::uuid; v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if v_id is null then raise exception 'Rule ID is required'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_id::text,6));
  select * into r from public.recurring_rule where id=v_id for update;
  if found then
    if r.owner_user_id<>v_uid then raise exception 'Rule not found'; end if;
    if p_expected_version is distinct from r.version then raise exception 'Recurring rule changed. Refresh and try again.'; end if;
  elsif p_expected_version is not null then raise exception 'Rule not found'; end if;
  perform private.validate_expense_payload(v_uid,(p_rule->>'paid_by')::uuid,(p_rule->>'amount_minor')::integer,p_rule->>'currency',p_rule->'shares');
  insert into public.recurring_rule(id,owner_user_id,paid_by,shares,amount_minor,currency,category,title,note,location,interval_unit,interval_count,start_date,end_date,next_occurrence,skipped_dates,is_active)
  values(v_id,v_uid,(p_rule->>'paid_by')::uuid,p_rule->'shares',(p_rule->>'amount_minor')::integer,p_rule->>'currency',(p_rule->>'category')::public.expense_category,
    p_rule->>'title',p_rule->>'note',nullif(p_rule->'location','null'::jsonb),p_rule->>'interval_unit',(p_rule->>'interval_count')::integer,
    (p_rule->>'start_date')::date,(p_rule->>'end_date')::date,(p_rule->>'next_occurrence')::date,
    array(select value::date from jsonb_array_elements_text(coalesce(p_rule->'skipped_dates','[]'::jsonb))),coalesce((p_rule->>'is_active')::boolean,true))
  on conflict(id) do update set paid_by=excluded.paid_by,shares=excluded.shares,amount_minor=excluded.amount_minor,currency=excluded.currency,category=excluded.category,
    title=excluded.title,note=excluded.note,location=excluded.location,interval_unit=excluded.interval_unit,interval_count=excluded.interval_count,
    start_date=excluded.start_date,end_date=excluded.end_date,next_occurrence=excluded.next_occurrence,skipped_dates=excluded.skipped_dates,is_active=excluded.is_active,version=public.recurring_rule.version+1;
  perform private.apply_custom_category(v_uid,p_rule,null,v_id);
  return v_id;
end $$;

-- The rule is saved first, so the seed expense picks up its category.
create or replace function public.create_recurring_expense(p_rule jsonb,p_expense jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_id uuid;
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if (p_expense->>'spent_at')::date is distinct from (p_rule->>'start_date')::date
    or (p_rule->>'next_occurrence')::date<=(p_rule->>'start_date')::date then raise exception 'Invalid recurring expense'; end if;
  -- Without an expected version this only creates; an existing ID is rejected.
  perform public.save_recurring_rule(p_rule,null);
  v_id:=private.save_expense_as(auth.uid(),p_expense||jsonb_build_object('recurring_id',p_rule->>'id'),null);
  perform private.apply_custom_category(auth.uid(),p_expense,v_id,null);
  return v_id;
end $$;

-- A suggestion can move an expense out of its custom category into Other.
-- Proposals only carry built-in categories, and 'other' alone keeps the custom
-- one (older builds send it for any custom category), so the move is explicit.
alter table public.expense_edit_proposal add column clears_custom_category boolean not null default false;

-- Same as before, plus clears_custom_category.
create or replace function public.create_expense_edit_proposal(p_expense_id uuid,p_expected_version bigint,p_proposal jsonb) returns uuid
language plpgsql security definer set search_path='' as $$
declare e public.expense; v_id uuid; v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  select * into e from public.expense where id=p_expense_id for update;
  if not found or e.created_by=v_uid or not exists(select 1 from public.expense_share where expense_id=e.id and user_id=v_uid)
    then raise exception 'Expense not found'; end if;
  if p_expected_version is distinct from e.version then raise exception 'Expense changed. Refresh and try again.'; end if;
  perform private.validate_expense_payload(e.created_by,(p_proposal->>'paid_by')::uuid,(p_proposal->>'amount_minor')::integer,e.currency,p_proposal->'shares');
  update public.expense_edit_proposal set status='withdrawn',responded_at=now() where expense_id=e.id and proposed_by=v_uid and status='pending';
  insert into public.expense_edit_proposal(expense_id,proposed_by,base_version,currency,amount_minor,category,title,note,location,spent_at,paid_by,shares,message,clears_custom_category)
  values(e.id,v_uid,e.version,e.currency,(p_proposal->>'amount_minor')::integer,(p_proposal->>'category')::public.expense_category,
    p_proposal->>'title',p_proposal->>'note',nullif(p_proposal->'location','null'::jsonb),(p_proposal->>'spent_at')::date,
    (p_proposal->>'paid_by')::uuid,p_proposal->'shares',p_proposal->>'message',
    coalesce((p_proposal->>'clears_custom_category')::boolean,false) and e.custom_category_id is not null and p_proposal->>'category'='other')
  returning id into v_id;
  perform private.log_expense_event('proposal_created',e,private.expense_shares(e.id),v_uid,array[v_uid,e.created_by]);
  return v_id;
end $$;

-- respond_to_edit_proposal saves the expense, then marks the proposal accepted.
create function private.apply_accepted_proposal_category() returns trigger
language plpgsql set search_path='' as $$
begin
  update public.expense set custom_category_id=null where id=new.expense_id and custom_category_id is not null;
  return null;
end $$;
revoke all on function private.apply_accepted_proposal_category() from public,anon,authenticated;
create trigger proposal_clears_custom_category after update of status on public.expense_edit_proposal
  for each row when (new.status='accepted' and old.status<>'accepted' and new.clears_custom_category)
  execute function private.apply_accepted_proposal_category();

-- Free accounts keep the categories they made but can't add or change them.
create function public.save_custom_category(p_id uuid,p_name text,p_symbol text,p_color_hex text) returns uuid
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_id uuid:=coalesce(p_id,gen_random_uuid());
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if not private.has_pro(v_uid) then raise exception 'Custom categories need Loam Pro'; end if;
  if exists(select 1 from public.custom_category where id=v_id and owner_id<>v_uid) then raise exception 'Category not found'; end if;
  if not exists(select 1 from public.custom_category where id=v_id)
    and (select count(*) from public.custom_category where owner_id=v_uid)>=50 then raise exception 'You can have up to 50 categories'; end if;
  insert into public.custom_category(id,owner_id,name,symbol,color_hex) values(v_id,v_uid,btrim(p_name),p_symbol,upper(p_color_hex))
  on conflict(id) do update set name=excluded.name,symbol=excluded.symbol,color_hex=excluded.color_hex;
  return v_id;
end $$;
revoke all on function public.save_custom_category(uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.save_custom_category(uuid,text,text,text) to authenticated;

create function public.delete_custom_category(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  delete from public.custom_category where id=p_id and owner_id=auth.uid();
end $$;
revoke all on function public.delete_custom_category(uuid) from public,anon,authenticated;
grant execute on function public.delete_custom_category(uuid) to authenticated;

-- Replaces the caller's hidden built-in categories. Other can't be hidden.
create function public.set_hidden_categories(p_categories public.expense_category[]) returns void
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if not private.has_pro(v_uid) then raise exception 'Removing categories needs Loam Pro'; end if;
  delete from public.hidden_category where user_id=v_uid;
  insert into public.hidden_category(user_id,category)
    select distinct v_uid,c from unnest(coalesce(p_categories,'{}')) c where c<>'other';
end $$;
revoke all on function public.set_hidden_categories(public.expense_category[]) from public,anon,authenticated;
grant execute on function public.set_hidden_categories(public.expense_category[]) to authenticated;

-- A deleted account's category names are personal data; shared expenses fall back to Other.
create function private.delete_closed_account_categories() returns trigger
language plpgsql set search_path='' as $$
begin
  delete from public.custom_category where owner_id=new.id;
  delete from public.hidden_category where user_id=new.id;
  return null;
end $$;
revoke all on function private.delete_closed_account_categories() from public,anon,authenticated;
create trigger profile_closed_categories after update of deleted_at on public.profile
  for each row when (old.deleted_at is null and new.deleted_at is not null)
  execute function private.delete_closed_account_categories();

notify pgrst,'reload schema';
