-- Allow household creator to add initial members (before owner row exists in batch inserts)

drop policy if exists "member_insert_owner_or_self_join" on public.household_member;

create policy "member_insert_owner_or_self_join"
  on public.household_member for insert
  with check (
    auth.uid() = user_id
    or public.is_household_owner(household_id)
    or exists (
      select 1 from public.household h
      where h.id = household_id
        and h.created_by = auth.uid()
    )
  );
