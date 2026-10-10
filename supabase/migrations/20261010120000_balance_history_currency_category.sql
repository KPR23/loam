-- The per-person history screen formats each row in its own currency and shows
-- the expense's category icon. Adding output columns changes the return type,
-- so the function is dropped and recreated with the same hardening as before.
drop function if exists public.balance_history(uuid);

create function public.balance_history(p_person_id uuid)
returns table(id uuid,kind text,title text,amount_minor integer,occurred_at timestamptz,status public.expense_share_status,currency text,category text)
language sql stable security definer set search_path='' as $$
  select e.id,'purchase',coalesce(e.title,e.category::text),
         case when e.paid_by=auth.uid() then s.amount_minor else -s.amount_minor end,
         e.spent_at::timestamptz,s.status,e.currency,e.category::text
  from public.expense e join public.expense_share s on s.expense_id=e.id
  where public.current_account_is_active()
    and ((e.paid_by=auth.uid() and s.user_id=p_person_id) or (e.paid_by=p_person_id and s.user_id=auth.uid()))
  union all
  select r.id,case when r.reversed_at is null then 'repayment' else 'reversal' end,
         coalesce(r.note,'Repayment'),case when r.to_user=auth.uid() then -r.amount_minor else r.amount_minor end,
         r.paid_at::timestamptz,null,r.currency,null
  from public.repayment r
  where public.current_account_is_active()
    and ((r.from_user=auth.uid() and r.to_user=p_person_id) or (r.to_user=auth.uid() and r.from_user=p_person_id))
  order by 5 desc
$$;

revoke all on function public.balance_history(uuid) from public,anon;
grant execute on function public.balance_history(uuid) to authenticated;

notify pgrst,'reload schema';
