-- Opening Activity clears its badge without reading anything: the tab badge and
-- the app icon count unread events the viewer hasn't seen yet, while the inbox
-- keeps listing every unread event until it is marked read.

alter table public.activity_event add column seen_at timestamptz;

-- Seen events stay unread, so the unread index keeps growing with them; badge
-- counts search only the events that still count.
create index activity_event_unseen_idx on public.activity_event(audience_user_id)
  where read_at is null and seen_at is null;

-- Capped at 100 so the tab badge stays cheap.
create function public.activity_unseen_count() returns integer
language sql stable security definer set search_path='' as $$
  select count(*)::integer from (select 1 from public.activity_event
    where public.current_account_is_active() and audience_user_id=auth.uid()
      and read_at is null and seen_at is null limit 100) u
$$;
revoke all on function public.activity_unseen_count() from public,anon,authenticated;
grant execute on function public.activity_unseen_count() to authenticated;

-- Marks the given unread events seen. Only events the viewer has loaded are
-- passed, so ones still waiting on later pages or arriving later keep counting.
create function public.mark_activity_seen(p_ids uuid[]) returns void
language plpgsql security definer set search_path='' as $$
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  update public.activity_event set seen_at=now()
  where audience_user_id=auth.uid() and read_at is null and seen_at is null and id=any(p_ids);
end $$;
revoke all on function public.mark_activity_seen(uuid[]) from public,anon,authenticated;
grant execute on function public.mark_activity_seen(uuid[]) to authenticated;

-- Same as before, but the badge counts only unseen events, like the tab.
create or replace function public.push_event_context(p_event_id uuid) returns table(
  user_id uuid,kind text,actor_id uuid,actor_name text,recipient_id uuid,recipient_name text,
  expense_id uuid,repayment_id uuid,expense_title text,affected_share_minor integer,currency text,
  badge integer,devices jsonb)
language sql stable security definer set search_path='' as $$
  select a.audience_user_id,a.kind,a.actor_id,public.activity_name(a.actor_id),a.recipient_id,
    case when a.recipient_id is not null then public.activity_name(a.recipient_id) end,
    a.expense_id,a.repayment_id,a.expense_title,a.affected_share_minor,a.currency,
    (select count(*)::integer from (select 1 from public.activity_event u
      where u.audience_user_id=a.audience_user_id and u.read_at is null and u.seen_at is null limit 100) c),
    (select coalesce(jsonb_agg(jsonb_build_object('token',d.token,'environment',d.environment)),'[]'::jsonb)
      from private.push_device d where d.user_id=a.audience_user_id)
  from public.activity_event a
  join public.profile pr on pr.id=a.audience_user_id and pr.deleted_at is null
  left join private.notification_preference p on p.user_id=a.audience_user_id
  where a.id=p_event_id and a.read_at is null and a.audience_user_id<>a.actor_id
    and case private.notification_category(a.kind)
      when 'requests' then coalesce(p.requests,true) when 'replies' then coalesce(p.replies,true)
      when 'repayments' then coalesce(p.repayments,true) else coalesce(p.changes,true) end
    and exists(select 1 from private.push_device d where d.user_id=a.audience_user_id)
$$;
revoke all on function public.push_event_context(uuid) from public,anon,authenticated;
grant execute on function public.push_event_context(uuid) to service_role;

notify pgrst,'reload schema';
