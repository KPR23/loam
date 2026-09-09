-- Split expenses: test partner seed + relax paid_by RLS for household splits

-- ---------------------------------------------------------------------------
-- Test partner (Alex) — FK-only placeholder. Hardened in 20260909000002.
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
