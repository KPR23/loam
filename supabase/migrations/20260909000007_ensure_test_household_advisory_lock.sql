-- P1: Serialize ensure_test_household per user to prevent duplicate households.

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
  v_is_creator boolean;
  v_is_owner boolean;
begin
  if v_user_id is null then
    raise exception 'Not authenticated';
  end if;

  if public.auth_is_placeholder_partner() then
    raise exception 'Placeholder partner cannot create households';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_user_id::text));

  -- Reuse only households the caller created or already owns (not any membership).
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
          and m.role = 'owner'
      )
    )
  order by h.created_at desc
  limit 1;

  if v_household_id is null then
    v_household_id := gen_random_uuid();

    insert into public.household (id, name, currency, created_by)
    values (v_household_id, 'Test splits', 'PLN', v_user_id);
  end if;

  select exists (
    select 1
    from public.household h
    where h.id = v_household_id
      and h.created_by = v_user_id
  )
  into v_is_creator;

  select exists (
    select 1
    from public.household_member m
    where m.household_id = v_household_id
      and m.user_id = v_user_id
      and m.role = 'owner'
  )
  into v_is_owner;

  if not v_is_creator and not v_is_owner then
    raise exception 'Not authorized to access this test household';
  end if;

  if v_is_creator then
    insert into public.household_member (household_id, user_id, display_name, role)
    values (v_household_id, v_user_id, p_display_name, 'owner')
    on conflict (household_id, user_id) do update
      set display_name = excluded.display_name,
          role = 'owner';
  else
    update public.household_member
    set display_name = p_display_name
    where household_id = v_household_id
      and user_id = v_user_id
      and role = 'owner';
  end if;

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
