-- Activity becomes an inbox: it lists unread events only, and read events
-- live on in each expense's history. An event is read when:
-- * the viewer caused it (own actions are never news),
-- * a newer event about the same expense or repayment reaches the viewer
--   (the newer one replaces it), or
-- * the viewer marks it read.

alter table public.activity_event add column read_at timestamptz;

create index activity_event_unread_idx on public.activity_event(audience_user_id,occurred_at desc,id desc)
  where read_at is null;

-- Existing history: keep only the newest event of each expense or repayment
-- from the last two weeks unread, so the inbox starts short.
update public.activity_event a set read_at=now()
where a.audience_user_id=a.actor_id
  or a.occurred_at<now()-interval '14 days'
  or exists(select 1 from public.activity_event b
    where b.audience_user_id=a.audience_user_id and b.id<>a.id
      and (b.expense_id=a.expense_id or b.repayment_id=a.repayment_id)
      and (b.occurred_at,b.id)>(a.occurred_at,a.id));

create function private.mark_own_activity_read() returns trigger
language plpgsql set search_path='' as $$
begin
  if new.audience_user_id=new.actor_id then new.read_at:=new.occurred_at; end if;
  return new;
end $$;
revoke all on function private.mark_own_activity_read() from public,anon,authenticated;
create trigger activity_own_read before insert on public.activity_event
  for each row execute function private.mark_own_activity_read();

create function private.mark_replaced_activity_read() returns trigger
language plpgsql set search_path='' as $$
begin
  update public.activity_event set read_at=now()
  where audience_user_id=new.audience_user_id and id<>new.id and read_at is null
    and (expense_id=new.expense_id or repayment_id=new.repayment_id)
    and occurred_at<=new.occurred_at;
  return null;
end $$;
revoke all on function private.mark_replaced_activity_read() from public,anon,authenticated;
create trigger activity_replaced_read after insert on public.activity_event
  for each row execute function private.mark_replaced_activity_read();

-- activity_page with only unread rows; same columns and cursor rules.
create function public.activity_inbox(p_before_id uuid default null)
returns table(id uuid,audience_user_id uuid,occurred_at timestamptz,kind text,actor_id uuid,actor_name text,
  recipient_id uuid,recipient_name text,recipient_names text[],recipient_ids uuid[],expense_id uuid,repayment_id uuid,expense_title text,
  category public.expense_category,affected_share_minor integer,expense_total_minor integer,currency text)
language sql stable security definer set search_path='' as $$
  select a.id,a.audience_user_id,a.occurred_at,a.kind,a.actor_id,public.activity_name(a.actor_id),
    a.recipient_id,case when a.recipient_id is not null then public.activity_name(a.recipient_id) end,
    array(select public.activity_name(r.id) from unnest(a.recipient_ids) with ordinality r(id,n) order by r.n),
    a.recipient_ids,a.expense_id,a.repayment_id,a.expense_title,a.category,a.affected_share_minor,a.expense_total_minor,a.currency
  from public.activity_event a
  where public.current_account_is_active() and a.audience_user_id=auth.uid() and a.read_at is null
    -- The cursor row may have been read since; its position still counts.
    and (p_before_id is null or (a.occurred_at,a.id)<
      (select b.occurred_at,b.id from public.activity_event b where b.id=p_before_id and b.audience_user_id=auth.uid()))
  order by a.occurred_at desc,a.id desc limit 51
$$;
revoke all on function public.activity_inbox(uuid) from public,anon,authenticated;
grant execute on function public.activity_inbox(uuid) to authenticated;

-- Capped at 100 so the tab badge stays cheap.
create function public.activity_unread_count() returns integer
language sql stable security definer set search_path='' as $$
  select count(*)::integer from (select 1 from public.activity_event
    where public.current_account_is_active() and audience_user_id=auth.uid() and read_at is null limit 100) u
$$;
revoke all on function public.activity_unread_count() from public,anon,authenticated;
grant execute on function public.activity_unread_count() to authenticated;

-- Marks the caller's own events read; other IDs are ignored.
create function public.mark_activity_read(p_ids uuid[]) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  update public.activity_event set read_at=now()
  where audience_user_id=auth.uid() and id=any(p_ids) and read_at is null;
end $$;
revoke all on function public.mark_activity_read(uuid[]) from public,anon,authenticated;
grant execute on function public.mark_activity_read(uuid[]) to authenticated;

notify pgrst,'reload schema';
