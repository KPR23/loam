-- P0: Alex (Test) is a FK-only placeholder. It must never authenticate or access data.

-- ---------------------------------------------------------------------------
-- Helper: block placeholder UUID from passing member checks even if a session exists
-- ---------------------------------------------------------------------------

create or replace function public.is_placeholder_partner(uid uuid)
returns boolean
language sql
immutable
as $$
  select uid = '00000000-0000-0000-0000-000000000001'::uuid;
$$;

create or replace function public.auth_is_placeholder_partner()
returns boolean
language sql
stable
as $$
  select public.is_placeholder_partner(auth.uid());
$$;

create or replace function public.is_household_member(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
    and not public.auth_is_placeholder_partner()
    and exists (
      select 1 from public.household_member m
      where m.household_id = hid and m.user_id = auth.uid()
    );
$$;

create or replace function public.is_household_owner(hid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
    and not public.auth_is_placeholder_partner()
    and exists (
      select 1 from public.household_member m
      where m.household_id = hid
        and m.user_id = auth.uid()
        and m.role = 'owner'
    );
$$;

-- ---------------------------------------------------------------------------
-- Disable authentication for the seeded placeholder identity
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  banned_until,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data,
  is_super_admin
)
values (
  '00000000-0000-0000-0000-000000000000',
  '00000000-0000-0000-0000-000000000001',
  'authenticated',
  'authenticated',
  'alex.test@loam.app',
  '',
  null,
  '9999-12-31 23:59:59+00'::timestamptz,
  now(),
  now(),
  '{"provider":"disabled","providers":[]}',
  '{"full_name":"Alex (Test)","is_placeholder":true}',
  false
)
on conflict (id) do update set
  encrypted_password = excluded.encrypted_password,
  email_confirmed_at = excluded.email_confirmed_at,
  banned_until = excluded.banned_until,
  raw_app_meta_data = excluded.raw_app_meta_data,
  raw_user_meta_data = excluded.raw_user_meta_data,
  is_super_admin = excluded.is_super_admin;

delete from auth.identities
where user_id = '00000000-0000-0000-0000-000000000001'::uuid;

insert into public.profile (id, display_name)
values ('00000000-0000-0000-0000-000000000001', 'Alex (Test)')
on conflict (id) do update set display_name = excluded.display_name;

-- Deny all API access when authenticated as the placeholder (defense in depth).
drop policy if exists "expense_select_own_or_household" on public.expense;
create policy "expense_select_own_or_household"
  on public.expense for select
  using (
    not public.auth_is_placeholder_partner()
    and (
      (household_id is null and created_by = auth.uid())
      or (household_id is not null and public.is_household_member(household_id))
    )
  );

drop policy if exists "expense_insert_own_or_household" on public.expense;
create policy "expense_insert_own_or_household"
  on public.expense for insert
  with check (
    not public.auth_is_placeholder_partner()
    and created_by = auth.uid()
    and (
      paid_by = auth.uid()
      or (
        household_id is not null
        and public.is_household_member(household_id)
        and exists (
          select 1 from public.household_member m
          where m.household_id = expense.household_id
            and m.user_id = paid_by
        )
      )
    )
    and (
      household_id is null
      or public.is_household_member(household_id)
    )
  );

drop policy if exists "expense_update_creator" on public.expense;
create policy "expense_update_creator"
  on public.expense for update
  using (
    not public.auth_is_placeholder_partner()
    and created_by = auth.uid()
    and (
      household_id is null
      or public.is_household_member(household_id)
    )
  );

drop policy if exists "expense_delete_creator" on public.expense;
create policy "expense_delete_creator"
  on public.expense for delete
  using (
    not public.auth_is_placeholder_partner()
    and created_by = auth.uid()
  );
