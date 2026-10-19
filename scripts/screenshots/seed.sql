-- Sample data for PR screenshots. Runs against a throwaway local Supabase stack after the PR's own
-- migrations, as the two users that scripts/screenshots/start-backend.sh creates. Everything is fake.
\set ON_ERROR_STOP on

begin;
select set_config('seed.julia', '00000000-0000-4000-8000-0000000000a1', true),
       set_config('seed.philip', '00000000-0000-4000-8000-0000000000b2', true);

insert into public.profile (id, display_name) values
  (current_setting('seed.julia')::uuid, 'Julia'),
  (current_setting('seed.philip')::uuid, 'Philip')
on conflict (id) do update set display_name = excluded.display_name;

insert into public.user_connection (user_a, user_b, created_by, accepted_at)
values (least(current_setting('seed.julia')::uuid, current_setting('seed.philip')::uuid),
        greatest(current_setting('seed.julia')::uuid, current_setting('seed.philip')::uuid),
        current_setting('seed.julia')::uuid, now());

-- Each row: days ago, amount in grosze, category, title, share paid by Julia and split with Philip (0 = private).
create function pg_temp.add_expense(p_days int, p_amount int, p_category text, p_title text, p_partner_share int)
returns void language plpgsql as $$
declare v_julia text := current_setting('seed.julia'); v_philip text := current_setting('seed.philip');
begin
  perform public.save_expense(jsonb_build_object(
    'id', gen_random_uuid(), 'amount_minor', p_amount, 'currency', 'PLN', 'category', p_category, 'title', p_title,
    'spent_at', current_date - p_days, 'paid_by', v_julia,
    'shares', case when p_partner_share = 0
      then jsonb_build_array(jsonb_build_object('user_id', v_julia, 'amount_minor', p_amount))
      else jsonb_build_array(jsonb_build_object('user_id', v_julia, 'amount_minor', p_amount - p_partner_share),
                             jsonb_build_object('user_id', v_philip, 'amount_minor', p_partner_share)) end));
end $$;

set local role authenticated;
select set_config('request.jwt.claim.sub', current_setting('seed.julia'), true);

select pg_temp.add_expense(0, 4850,  'groceries',     'Weekly shop',        2425),
       pg_temp.add_expense(0, 1890,  'dining',        'Lunch with Philip',  945),
       pg_temp.add_expense(1, 3200,  'transport',     'Train tickets',      0),
       pg_temp.add_expense(1, 2400,  'entertainment', 'Cinema',             1200),
       pg_temp.add_expense(2, 12900, 'shopping',      'Running shoes',      0),
       pg_temp.add_expense(3, 8700,  'utilities',     'Internet',           4350),
       pg_temp.add_expense(3, 1550,  'dining',        'Coffee and cake',    0),
       pg_temp.add_expense(4, 5600,  'health',        'Pharmacy',           0),
       pg_temp.add_expense(5, 21000, 'travel',        'Weekend trip',       10500),
       pg_temp.add_expense(6, 6400,  'groceries',     'Farmers market',     3200);

-- Philip accepts the shared ones, so they show up in the balance rather than as waiting.
select set_config('request.jwt.claim.sub', current_setting('seed.philip'), true);
select public.respond_to_expense_share(e.id, 'accept')
from public.expense e
where e.paid_by = current_setting('seed.julia')::uuid
  and exists (select 1 from public.expense_share s where s.expense_id = e.id and s.user_id = current_setting('seed.philip')::uuid);

reset role;
commit;
