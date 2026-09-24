-- Clients only read these tables; writes go through RPCs. RLS already denies
-- most direct writes, but grants are the first boundary and RLS never
-- applies to TRUNCATE.
revoke all on public.profile,public.repayment,public.user_connection,public.connection_invitation from authenticated;
grant select on public.profile,public.repayment,public.user_connection,public.connection_invitation to authenticated;

-- Display names change through update_display_name(). The app writes only
-- the avatar pointer after uploading to its own storage folder.
grant update(avatar_path) on public.profile to authenticated;
alter table public.profile add constraint profile_avatar_path_own_folder
  check(avatar_path is null or avatar_path ~ ('^'||id::text||'/[0-9a-f-]{36}\.jpg$'));
