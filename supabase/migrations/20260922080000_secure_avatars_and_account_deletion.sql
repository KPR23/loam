-- Apply the private-avatar setting to projects where the original avatar
-- migration has already run, and permit signed reads only for the same people
-- allowed to read the profile row.
update storage.buckets
set public = false
where id = 'avatars';

drop policy if exists "avatar_select_own" on storage.objects;
drop policy if exists "avatar_select_self_or_connection" on storage.objects;
create policy "avatar_select_self_or_connection" on storage.objects
  for select to authenticated
  using (
    (
      bucket_id = 'avatars'
      and (storage.foldername(name))[1] = (select auth.uid())::text
    )
    or (
      bucket_id = 'avatars'
      and public.are_connected(
        (select auth.uid()),
        case
          when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
            then (storage.foldername(name))[1]::uuid
          else null
        end
      )
    )
  );

notify pgrst, 'reload schema';
