-- The output column `expires_at` in this PL/pgSQL function shares its name
-- with the invitation column, so table fields must remain explicitly scoped.
create or replace function public.create_connection_invitation()
returns table(code text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare v_user_id uuid := (select auth.uid()); v_code text; v_expiry timestamptz := now() + interval '24 hours';
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  if not exists (select 1 from public.profile p where p.id = v_user_id and p.deleted_at is null) then raise exception 'Account unavailable'; end if;
  perform public.assert_connection_code_rate('create', 10, interval '1 hour');
  update public.connection_invitation as i
  set expires_at = now()
  where i.created_by = v_user_id and i.accepted_at is null and i.expires_at > now();
  loop
    v_code := public.connection_code_value();
    begin
      insert into public.connection_invitation(code, created_by, expires_at) values (v_code, v_user_id, v_expiry);
      exit;
    exception when unique_violation then end;
  end loop;
  return query select v_code, v_expiry;
end;
$$;

grant execute on function public.create_connection_invitation() to authenticated;
notify pgrst, 'reload schema';
