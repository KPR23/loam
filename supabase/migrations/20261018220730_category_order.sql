-- Pro members choose the order of their category picker. The order is a list of
-- keys: a built-in category's name or a custom category's id. Categories missing
-- from the list (new ones, restored ones) follow the listed ones.

create table public.category_order(
  user_id uuid primary key references auth.users(id) on delete cascade,
  keys text[] not null default '{}' check(cardinality(keys)<=100)
);
alter table public.category_order enable row level security;
revoke all on public.category_order from public,anon,authenticated;
grant select on public.category_order to authenticated;
create policy category_order_read on public.category_order for select to authenticated using (user_id=(select auth.uid()));

-- Replaces the caller's order.
create function public.set_category_order(p_keys text[]) returns void
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid();
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  if not private.has_pro(v_uid) then raise exception 'Reordering categories needs Loam Pro'; end if;
  if cardinality(coalesce(p_keys,'{}'))>100 then raise exception 'Too many categories'; end if;
  insert into public.category_order(user_id,keys) values(v_uid,coalesce(p_keys,'{}'))
  on conflict(user_id) do update set keys=excluded.keys;
end $$;
revoke all on function public.set_category_order(text[]) from public,anon,authenticated;
grant execute on function public.set_category_order(text[]) to authenticated;

-- A deleted account's order is personal data too.
create or replace function private.delete_closed_account_categories() returns trigger
language plpgsql set search_path='' as $$
begin
  delete from public.custom_category where owner_id=new.id;
  delete from public.hidden_category where user_id=new.id;
  delete from public.category_order where user_id=new.id;
  return null;
end $$;

notify pgrst,'reload schema';
