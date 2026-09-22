-- Balances and repayments cannot combine different currencies without an
-- explicit exchange-rate policy. Keep every pairwise balance currency-scoped.
alter table public.repayment drop constraint if exists repayment_currency_check;
alter table public.repayment
  add constraint repayment_currency_check check (currency in ('PLN', 'EUR', 'USD'));

drop function if exists public.create_repayment(uuid, integer, text, date, uuid);
drop function if exists public.balance_snapshot();

create function public.balance_snapshot()
returns table(person_id uuid, display_name text, currency text, amount_minor integer)
language sql stable security definer set search_path = public as $$
  with obligations as (
    select case when e.paid_by = auth.uid() then s.user_id else e.paid_by end as other_id,
           e.currency,
           case when e.paid_by = auth.uid() then s.amount_minor else -s.amount_minor end as delta
    from public.expense e
    join public.expense_share s on s.expense_id = e.id
    join public.expense_share payer on payer.expense_id = e.id and payer.user_id = e.paid_by
    where s.user_id <> e.paid_by
      and (e.paid_by = auth.uid() or s.user_id = auth.uid())
      and s.status = 'accepted' and payer.status = 'accepted'
  ), payments as (
    select case when r.to_user = auth.uid() then r.from_user else r.to_user end as other_id,
           r.currency,
           case when r.to_user = auth.uid() then -r.amount_minor else r.amount_minor end as delta
    from public.repayment r
    where auth.uid() in (r.from_user, r.to_user) and r.reversed_at is null
  ), net as (
    select other_id, currency, sum(delta)::integer as amount_minor
    from (select * from obligations union all select * from payments) x
    group by other_id, currency
  )
  select n.other_id, coalesce(p.display_name, 'Connected person'), n.currency, n.amount_minor
  from net n join public.profile p on p.id = n.other_id
  where n.amount_minor <> 0;
$$;

create function public.create_repayment(
  p_to_user_id uuid,
  p_amount_minor integer,
  p_currency text,
  p_note text,
  p_paid_at date,
  p_operation_id uuid
)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_debt integer;
begin
  if auth.uid() is null or p_amount_minor <= 0 or p_to_user_id = auth.uid()
     or p_currency not in ('PLN', 'EUR', 'USD') then
    raise exception 'Invalid repayment';
  end if;

  select id into v_id from public.repayment
  where operation_id = p_operation_id and from_user = auth.uid();
  if v_id is not null then return v_id; end if;

  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || p_to_user_id::text || p_currency, 0));
  select id into v_id from public.repayment
  where operation_id = p_operation_id and from_user = auth.uid();
  if v_id is not null then return v_id; end if;

  select -amount_minor into v_debt
  from public.balance_snapshot()
  where person_id = p_to_user_id and currency = p_currency;
  if coalesce(v_debt, 0) < p_amount_minor then
    raise exception 'Repayment exceeds confirmed debt';
  end if;

  insert into public.repayment(from_user, to_user, amount_minor, currency, note, paid_at, operation_id)
  values (auth.uid(), p_to_user_id, p_amount_minor, p_currency, p_note, p_paid_at, p_operation_id)
  returning id into v_id;
  return v_id;
end;
$$;

revoke all on function public.balance_snapshot(), public.create_repayment(uuid, integer, text, text, date, uuid) from public;
grant execute on function public.balance_snapshot(), public.create_repayment(uuid, integer, text, text, date, uuid) to authenticated;

notify pgrst, 'reload schema';
