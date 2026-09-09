-- Split expenses: test partner seed + relax paid_by RLS for household splits

-- ---------------------------------------------------------------------------
-- Test partner (Alex) for development splits
-- Login disabled; fixed bcrypt hash avoids pgcrypto dependency in migrations.
-- ---------------------------------------------------------------------------

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
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
  '$2a$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy',
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}',
  '{"full_name":"Alex (Test)"}',
  false
)
on conflict (id) do nothing;

insert into public.profile (id, display_name)
values ('00000000-0000-0000-0000-000000000001', 'Alex (Test)')
on conflict (id) do update set display_name = excluded.display_name;

-- ---------------------------------------------------------------------------
-- Allow logging household expenses paid by another household member
-- ---------------------------------------------------------------------------

drop policy if exists "expense_insert_own_or_household" on public.expense;

create policy "expense_insert_own_or_household"
  on public.expense for insert
  with check (
    created_by = auth.uid()
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
