-- Expenses and repayments carry only a calendar date, so rows from the same day came back
-- in no particular order. Break ties by when each row was recorded, newest first.
create or replace function public.balance_history(p_person_id uuid)
returns table(id uuid,kind text,title text,amount_minor integer,occurred_at timestamptz,status public.expense_share_status,currency text,category text,payer_status public.expense_share_status)
language sql stable security definer set search_path='' as $$
  select h.id,h.kind,h.title,h.amount_minor,h.occurred_at,h.status,h.currency,h.category,h.payer_status
  from (
    select e.id,'purchase' as kind,coalesce(e.title,e.category::text) as title,
           case when e.paid_by=auth.uid() then s.amount_minor else -s.amount_minor end as amount_minor,
           e.spent_at::timestamptz as occurred_at,s.status,e.currency,e.category::text as category,payer.status as payer_status,
           e.created_at as recorded_at
    from public.expense e join public.expense_share s on s.expense_id=e.id
      left join public.expense_share payer on payer.expense_id=e.id and payer.user_id=e.paid_by
    where public.current_account_is_active()
      and ((e.paid_by=auth.uid() and s.user_id=p_person_id) or (e.paid_by=p_person_id and s.user_id=auth.uid()))
    union all
    select r.id,case when r.reversed_at is null then 'repayment' else 'reversal' end,
           coalesce(r.note,'Repayment'),case when r.to_user=auth.uid() then -r.amount_minor else r.amount_minor end,
           r.paid_at::timestamptz,null,r.currency,null,null,r.created_at
    from public.repayment r
    where public.current_account_is_active()
      and ((r.from_user=auth.uid() and r.to_user=p_person_id) or (r.to_user=auth.uid() and r.from_user=p_person_id))
  ) h
  order by h.occurred_at desc,h.recorded_at desc
$$;

notify pgrst,'reload schema';
