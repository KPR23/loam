-- Create or reuse an exact-member split household for real authenticated users.
-- This replaces the legacy debug flow that routed fake UUIDs to UserDefaults.

create or replace function public.ensure_split_household(
  p_display_name text,
  p_partner_ids uuid[]
)
returns table (
  id uuid,
  name text,
  currency text,
  created_by uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_partner_ids uuid[];
  v_partner_id uuid;
  v_household_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  select coalesce(array_agg(distinct partner_id order by partner_id), '{}'::uuid[])
  into v_partner_ids
  from unnest(coalesce(p_partner_ids, '{}'::uuid[])) partner_id
  where partner_id is not null and partner_id <> v_user_id;

  if cardinality(v_partner_ids) = 0 or cardinality(v_partner_ids) > 8 then
    raise exception 'Choose between 1 and 8 partners';
  end if;

  if exists (
    select 1
    from unnest(v_partner_ids) partner_id
    where public.is_placeholder_partner(partner_id)
      or not exists (select 1 from auth.users u where u.id = partner_id)
      or not public.are_connected(v_user_id, partner_id)
  ) then
    raise exception 'Every split participant must be a connected user';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(v_user_id::text || ':' || array_to_string(v_partner_ids, ','), 0)
  );

  select h.id
  into v_household_id
  from public.household h
  where h.created_by = v_user_id
    and exists (
      select 1 from public.household_member mine
      where mine.household_id = h.id and mine.user_id = v_user_id
    )
    and (
      select array_agg(m.user_id order by m.user_id)
      from public.household_member m
      where m.household_id = h.id and m.user_id <> v_user_id
    ) = v_partner_ids
  order by h.created_at desc
  limit 1;

  if v_household_id is null then
    v_household_id := gen_random_uuid();
    insert into public.household (id, name, currency, created_by)
    values (v_household_id, 'Splits', 'PLN', v_user_id);
  end if;

  insert into public.household_member (household_id, user_id, display_name, role)
  values (
    v_household_id,
    v_user_id,
    coalesce(nullif(btrim(p_display_name), ''), 'You'),
    'owner'
  )
  on conflict (household_id, user_id) do update
    set display_name = excluded.display_name,
        role = 'owner';

  foreach v_partner_id in array v_partner_ids
  loop
    insert into public.household_member (household_id, user_id, display_name, role)
    select
      v_household_id,
      v_partner_id,
      coalesce(nullif(btrim(p.display_name), ''), 'Connected person'),
      'member'
    from public.profile p
    where p.id = v_partner_id
    on conflict (household_id, user_id) do update
      set display_name = excluded.display_name;
  end loop;

  return query
  select h.id, h.name, h.currency, h.created_by
  from public.household h
  where h.id = v_household_id;
end;
$$;

revoke all on function public.ensure_split_household(text, uuid[]) from public;
grant execute on function public.ensure_split_household(text, uuid[]) to authenticated;

notify pgrst, 'reload schema';
