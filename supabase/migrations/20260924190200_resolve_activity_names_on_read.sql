-- Activity rows copied display names, which went stale after renames and
-- forced account deletion to scrub history by matching name text (clearing
-- unrelated people who shared a name). Rows now store user IDs and names
-- are resolved when the feed is read; a deleted profile already reads
-- "Deleted user". Expense amounts and titles stay snapshots: the feed
-- records what happened at the time, including for deleted expenses.
alter table public.activity_event add column recipient_ids uuid[] not null default '{}';
-- Pre-production rows cannot be mapped back from names; they keep their
-- actor and recipient but lose the "with ..." list.
alter table public.activity_event drop column actor_name,drop column recipient_name,drop column recipient_names;

create or replace function private.log_expense_event(p_kind text,p_expense public.expense,p_shares jsonb,p_actor uuid,p_audience uuid[] default null)
returns void language plpgsql set search_path='' as $$
begin
  if jsonb_array_length(p_shares)<2 then return; end if;
  insert into public.activity_event(audience_user_id,kind,actor_id,recipient_id,recipient_ids,
    expense_id,expense_title,category,affected_share_minor,expense_total_minor,currency)
  select (s->>'user_id')::uuid,p_kind,p_actor,
    case when p_actor<>p_expense.created_by then p_expense.created_by end,
    array(select (x->>'user_id')::uuid from jsonb_array_elements(p_shares) x where (x->>'user_id')::uuid<>p_actor),
    p_expense.id,coalesce(nullif(p_expense.title,''),initcap(p_expense.category::text)),p_expense.category,
    (s->>'amount_minor')::integer,p_expense.amount_minor,p_expense.currency
  from jsonb_array_elements(p_shares) s where p_audience is null or (s->>'user_id')::uuid=any(p_audience);
end $$;

-- Definer so viewers see co-participants' names even when they are not
-- connected to them directly; rows are limited to the caller's own feed.
drop function public.activity_page(uuid);
create function public.activity_page(p_before_id uuid default null)
returns table(id uuid,audience_user_id uuid,occurred_at timestamptz,kind text,actor_id uuid,actor_name text,
  recipient_id uuid,recipient_name text,recipient_names text[],expense_id uuid,expense_title text,
  category public.expense_category,affected_share_minor integer,expense_total_minor integer,currency text)
language sql stable security definer set search_path='' as $$
  select a.id,a.audience_user_id,a.occurred_at,a.kind,a.actor_id,public.activity_name(a.actor_id),
    a.recipient_id,case when a.recipient_id is not null then public.activity_name(a.recipient_id) end,
    array(select public.activity_name(r.id) from unnest(a.recipient_ids) with ordinality r(id,n) order by r.n),
    a.expense_id,a.expense_title,a.category,a.affected_share_minor,a.expense_total_minor,a.currency
  from public.activity_event a
  where public.current_account_is_active() and a.audience_user_id=auth.uid()
    and (p_before_id is null or (a.occurred_at,a.id)<
      (select b.occurred_at,b.id from public.activity_event b where b.id=p_before_id and b.audience_user_id=auth.uid()))
  order by a.occurred_at desc,a.id desc limit 51
$$;
revoke all on function public.activity_page(uuid) from public,anon,authenticated;
grant execute on function public.activity_page(uuid) to authenticated;

create or replace function public.redact_account_data(p_user_id uuid) returns void
language plpgsql set search_path='' as $$
begin
  if p_user_id is null then raise exception 'User ID is required'; end if;
  -- Activity resolves names from the profile, so this also redacts history.
  update public.profile set display_name='Deleted user',avatar_path=null,deleted_at=now() where id=p_user_id;
  if not found then raise exception 'Profile not found for account deletion'; end if;

  -- Private expenses are visible only to this account. Shared transactions,
  -- shares and repayments remain intact for the other participants.
  delete from public.expense
  where created_by=p_user_id and not exists(select 1 from public.expense_share s where s.expense_id=expense.id and s.user_id<>p_user_id);
  update public.recurring_rule r set is_active=false,version=version+1
  where owner_user_id<>p_user_id and exists(select 1 from jsonb_array_elements(r.shares) s where (s->>'user_id')::uuid=p_user_id);
  delete from public.recurring_rule where owner_user_id=p_user_id;
  delete from public.activity_event where audience_user_id=p_user_id;
  delete from public.connection_invitation where created_by=p_user_id or invited_user_id=p_user_id;
  delete from public.expense_share_trust where user_id=p_user_id or trusted_user_id=p_user_id;
  delete from public.user_connection where user_a=p_user_id or user_b=p_user_id;
end $$;

notify pgrst,'reload schema';
