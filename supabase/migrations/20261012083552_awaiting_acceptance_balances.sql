-- What people owe the viewer for expenses the viewer paid that they haven't
-- accepted yet. balance_snapshot leaves these out until they are accepted, so
-- Balances shows them separately as waiting on the other person.
create function public.awaiting_acceptance_snapshot()
returns table(person_id uuid,display_name text,currency text,amount_minor bigint,expense_count integer)
language sql stable security definer set search_path='' as $$
  select s.user_id,coalesce(p.display_name,'Connected person'),e.currency,sum(s.amount_minor)::bigint,count(*)::integer
  from public.expense e
  join public.expense_share s on s.expense_id=e.id
  join public.expense_share payer on payer.expense_id=e.id and payer.user_id=e.paid_by
  join public.profile p on p.id=s.user_id
  where public.current_account_is_active() and e.paid_by=auth.uid() and s.user_id<>e.paid_by
    and payer.status='accepted' and s.status='pending' and s.amount_minor>0
  group by s.user_id,p.display_name,e.currency
$$;
revoke all on function public.awaiting_acceptance_snapshot() from public,anon,authenticated;
grant execute on function public.awaiting_acceptance_snapshot() to authenticated;

notify pgrst,'reload schema';
