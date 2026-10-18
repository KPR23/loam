-- Home search: find the caller's own expenses by title, note or place name.
-- Trigram indexes keep substring matches (ILIKE '%text%') fast as history grows.
create extension if not exists pg_trgm with schema extensions;

create index expense_title_trgm_idx on public.expense using gin (title extensions.gin_trgm_ops) where title is not null;
create index expense_note_trgm_idx on public.expense using gin (note extensions.gin_trgm_ops) where note is not null;
create index expense_place_trgm_idx on public.expense using gin ((location->>'name') extensions.gin_trgm_ops) where location is not null;

-- Returns ids only; the client loads rows through the normal expense query so one
-- mapping serves both. SECURITY INVOKER keeps row-level security in force, and the
-- predicate repeats it on purpose: only expenses the caller created or holds a
-- non-rejected share of can ever match, whatever the policies say.
create function public.search_expenses(p_query text, p_limit integer default 50)
returns setof uuid
language sql stable security invoker set search_path='' as $$
  with q as (
    select '%' || replace(replace(replace(btrim(left(p_query, 100)), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern,
           char_length(btrim(left(p_query, 100))) as len
  )
  select e.id
  from public.expense e, q
  where q.len >= 2
    and (select auth.uid()) is not null
    and public.current_account_is_active()
    and (e.title ilike q.pattern or e.note ilike q.pattern or e.location->>'name' ilike q.pattern)
    and (e.created_by = (select auth.uid())
      or exists (select 1 from public.expense_share s
                 where s.expense_id = e.id and s.user_id = (select auth.uid()) and s.status <> 'rejected'))
  order by e.spent_at desc, e.created_at desc, e.id desc
  limit greatest(1, least(coalesce(p_limit, 50), 100))
$$;

revoke all on function public.search_expenses(text, integer) from public, anon, authenticated;
grant execute on function public.search_expenses(text, integer) to authenticated;

notify pgrst,'reload schema';
