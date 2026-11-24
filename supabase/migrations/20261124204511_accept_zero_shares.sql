-- A participant whose share is 0 and who didn't pay owes nothing, so there is
-- nothing for them to accept. Their share is accepted as soon as it is written
-- instead of waiting in their pending list.
--
-- * A BEFORE trigger on expense_share, like auto_accept_share. It fires on every
--   row private.save_expense_as upserts, so new expenses, edits, applied
--   proposals and recurring occurrences are all covered. Its name sorts before
--   expense_share_auto_accept, so the share is not recorded as auto-accepted.
-- * The payer still answers even with a 0 share: they are the one being owed.
-- * A rejection is left alone; only a pending share is answered.
-- * Shares already waiting at 0 are accepted once, here.

create function private.accept_zero_share() returns trigger
language plpgsql security definer set search_path='' as $$
begin
  if new.status='pending' and new.amount_minor=0
     and new.user_id is distinct from (select paid_by from public.expense where id=new.expense_id)
  then
    new.status:='accepted';
    new.responded_at:=now();
    new.accepted_via_trust:=false;
  end if;
  return new;
end $$;
revoke all on function private.accept_zero_share() from public,anon,authenticated;

create trigger expense_share_accept_zero before insert or update on public.expense_share
for each row execute function private.accept_zero_share();

update public.expense_share s set status='accepted',responded_at=now(),accepted_via_trust=false
from public.expense e
where e.id=s.expense_id and s.status='pending' and s.amount_minor=0 and s.user_id<>e.paid_by;
