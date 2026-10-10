-- Auto-accept: an account can accept every expense others share with them, whoever
-- creates it, instead of trusting people one at a time.
--
-- * profile.auto_accept_expenses is the switch, changed through
--   set_auto_accept_expenses (clients only hold UPDATE on avatar_path).
-- * A BEFORE trigger on expense_share turns a share that would start out pending into
--   an accepted one for such an account. It fires on the row proposed by the upsert in
--   private.save_expense_as, so the existing "keep an unchanged answer" rules still
--   decide whether an old response survives an edit, and an explicit rejection of an
--   unchanged amount stays rejected.
-- * Enabling the switch accepts every pending share of the account at once.
-- * The share is recorded as accepted through trust, so Activity shows it as
--   auto-accepted and the sender learns it needed no answer.

alter table public.profile add column auto_accept_expenses boolean not null default false;

create function public.set_auto_accept_expenses(p_enabled boolean) returns void
language plpgsql security definer set search_path='' as $$
declare v_uid uuid:=auth.uid(); v_id uuid; v_ids uuid[]; e public.expense;
begin
  if not public.current_account_is_active() then raise exception 'Not authenticated'; end if;
  update public.profile set auto_accept_expenses=coalesce(p_enabled,false) where id=v_uid;
  -- Turning it on also answers the requests already waiting, whatever their date,
  -- and records each answer the way respond_to_expense_share does.
  if coalesce(p_enabled,false) then
    -- Only shares this statement actually changed are logged; one rejected meanwhile stays out.
    with accepted as (
      update public.expense_share set status='accepted',responded_at=now(),accepted_via_trust=true
      where user_id=v_uid and status='pending' returning expense_id
    ) select coalesce(array_agg(expense_id),'{}') into v_ids from accepted;
    foreach v_id in array v_ids loop
      select * into e from public.expense where id=v_id;
      perform private.log_expense_event('accepted',e,private.expense_shares(v_id),v_uid,array[v_uid,e.created_by]);
    end loop;
  end if;
end $$;
revoke all on function public.set_auto_accept_expenses(boolean) from public,anon;
grant execute on function public.set_auto_accept_expenses(boolean) to authenticated;

create function private.auto_accept_share() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status='pending'
     and (tg_op='INSERT' or new.status is distinct from old.status or new.amount_minor is distinct from old.amount_minor)
     and exists(select 1 from public.profile where id=new.user_id and auto_accept_expenses and deleted_at is null)
  then
    new.status:='accepted';
    new.responded_at:=now();
    new.accepted_via_trust:=true;
  end if;
  return new;
end $$;
revoke all on function private.auto_accept_share() from public,anon,authenticated;

create trigger expense_share_auto_accept before insert or update on public.expense_share
for each row execute function private.auto_accept_share();

notify pgrst, 'reload schema';
