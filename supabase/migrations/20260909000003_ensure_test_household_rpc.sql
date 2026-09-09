-- Atomically create or reconcile the debug test household (household + both members).

create or replace function public.ensure_test_household(p_display_name text)
returns table (
  id uuid,
  name text,
  currency text,
  created_by uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_partner_id uuid := '00000000-0000-0000-0000-000000000001'::uuid;
  v_household_id uuid;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if public.auth_is_placeholder_partner() then
    raise exception 'Placeholder partner cannot create households';
  end if;

  -- Reuse the newest test household owned by or joined by the caller.
  select h.id
  into v_household_id
  from public.household h
  where h.name = 'Test splits'
    and (
      h.created_by = v_user_id
      or exists (
        select 1
        from public.household_member m
        where m.household_id = h.id
          and m.user_id = v_user_id
      )
    )
  order by h.created_at desc
  limit 1;

  if v_household_id is null then
    v_household_id := gen_random_uuid();

    insert into public.household (id, name, currency, created_by)
    values (v_household_id, 'Test splits', 'PLN', v_user_id);
  end if;

  insert into public.household_member (household_id, user_id, display_name, role)
  values (v_household_id, v_user_id, p_display_name, 'owner')
  on conflict (household_id, user_id) do update
    set display_name = excluded.display_name,
        role = 'owner';

  insert into public.household_member (household_id, user_id, display_name, role)
  values (v_household_id, v_partner_id, 'Alex (Test)', 'member')
  on conflict (household_id, user_id) do nothing;

  return query
  select h.id, h.name, h.currency, h.created_by
  from public.household h
  where h.id = v_household_id;
end;
$$;

revoke all on function public.ensure_test_household(text) from public;
grant execute on function public.ensure_test_household(text) to authenticated;
