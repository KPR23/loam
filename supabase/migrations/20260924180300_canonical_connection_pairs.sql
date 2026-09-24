-- Store each connection once as (lower id, higher id). The plain unique key
-- then covers both directions and doubles as the user_a lookup index, so
-- the expression index on least/greatest is redundant.
update public.user_connection set user_a=user_b,user_b=user_a where user_a>user_b;
alter table public.user_connection add constraint user_connection_canonical_order check(user_a<user_b);
alter table public.user_connection drop constraint user_connection_check;

create or replace function public.redeem_connection_code(p_code text)
returns table(user_id uuid,display_name text,error_code text)
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_inviter uuid; v_name text; v_code text:=public.normalized_connection_code(p_code);
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  begin perform public.assert_connection_code_rate('attempt',10,interval '15 minutes');
  exception when raise_exception then return query select null::uuid,null::text,'rate_limited'::text; return; end;
  select i.created_by,p.display_name into v_inviter,v_name from public.connection_invitation i join public.profile p on p.id=i.created_by
    where i.code=v_code and i.accepted_at is null and i.expires_at>now() and p.deleted_at is null for update of i;
  if not found or v_inviter=v_uid then return query select null::uuid,null::text,'unavailable'::text; return; end if;
  insert into public.user_connection(user_a,user_b,created_by,accepted_at)
    values(least(v_uid,v_inviter),greatest(v_uid,v_inviter),v_uid,now())
    on conflict on constraint user_connection_user_a_user_b_key do update set accepted_at=coalesce(user_connection.accepted_at,excluded.accepted_at);
  update public.connection_invitation set accepted_at=now(),invited_user_id=v_uid where code=v_code;
  return query select v_inviter,coalesce(v_name,'Connected person'),null::text;
end $$;

drop index public.user_connection_unordered_pair_key;
