-- A profile picture is chosen in Loam. Sign in with Apple does not return one.
alter table public.profile add column avatar_path text;

-- A person can read the avatar of an accepted connection, as well as their own.
drop policy if exists "profile_select_own" on public.profile;
create policy "profile_select_self_or_connection" on public.profile
  for select to authenticated
  using (
    id = (select auth.uid())
    or public.are_connected((select auth.uid()), id)
  );

-- Public downloads let a connected person's avatar render through AsyncImage.
-- Upload and deletion remain limited to the signed-in owner's UUID folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy "avatar_upload_own" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
    and storage.extension(name) = 'jpg'
  );

create policy "avatar_delete_own" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "avatar_select_own" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

grant select, update on public.profile to authenticated;
notify pgrst, 'reload schema';
