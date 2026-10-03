-- The last SECURITY DEFINER functions still resolved names through public.
-- Their bodies are schema-qualified, so an empty path changes nothing else.
alter function public.balance_snapshot() set search_path='';
alter function public.create_repayment(uuid,integer,text,text,date,uuid) set search_path='';
alter function public.reverse_repayment(uuid,uuid) set search_path='';
alter function public.handle_new_user() set search_path='';

-- Also require an active account, like every other financial read.
create or replace function public.balance_history(p_person_id uuid)
returns table(id uuid,kind text,title text,amount_minor integer,occurred_at timestamptz,status public.expense_share_status)
language sql stable security definer set search_path='' as $$
  select e.id,'purchase',coalesce(e.title,e.category::text),
         case when e.paid_by=auth.uid() then s.amount_minor else -s.amount_minor end,
         e.spent_at::timestamptz,s.status
  from public.expense e join public.expense_share s on s.expense_id=e.id
  where public.current_account_is_active()
    and ((e.paid_by=auth.uid() and s.user_id=p_person_id) or (e.paid_by=p_person_id and s.user_id=auth.uid()))
  union all
  select r.id,case when r.reversed_at is null then 'repayment' else 'reversal' end,
         coalesce(r.note,'Repayment'),case when r.to_user=auth.uid() then -r.amount_minor else r.amount_minor end,
         r.paid_at::timestamptz,null
  from public.repayment r
  where public.current_account_is_active()
    and ((r.from_user=auth.uid() and r.to_user=p_person_id) or (r.to_user=auth.uid() and r.from_user=p_person_id))
  order by 5 desc
$$;
