-- Keep one logical shared-expense event shape for clients that need to show
-- all participants in one activity row. The existing audience rows remain
-- compatible with the initial history migration; the client coalesces them.
alter table public.activity_event
  add column if not exists recipient_names text[] not null default '{}';

create index if not exists activity_event_expense_kind_idx
  on public.activity_event (expense_id, kind, occurred_at);

create or replace function public.log_share_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_expense public.expense%rowtype; v_kind text; v_names text[];
begin
  select * into v_expense from public.expense where id = new.expense_id;
  if v_expense.household_id is null or new.user_id = v_expense.created_by then return new; end if;
  v_kind := case when new.status = 'accepted' and new.accepted_via_trust then 'auto_accepted' else 'shared' end;
  select coalesce(array_agg(public.activity_name(user_id) order by user_id), '{}')
    into v_names from public.expense_share where expense_id = new.expense_id and user_id <> v_expense.created_by;
  insert into public.activity_event (audience_user_id, kind, actor_id, actor_name, recipient_id, recipient_name, recipient_names, expense_id, expense_title, category, affected_share_minor, expense_total_minor, currency)
  values (new.user_id, v_kind, v_expense.created_by, public.activity_name(v_expense.created_by), new.user_id, public.activity_name(new.user_id), v_names, v_expense.id, coalesce(v_expense.title, initcap(v_expense.category::text)), v_expense.category, new.amount_minor, v_expense.amount_minor, v_expense.currency),
         (v_expense.created_by, v_kind, v_expense.created_by, public.activity_name(v_expense.created_by), new.user_id, public.activity_name(new.user_id), v_names, v_expense.id, coalesce(v_expense.title, initcap(v_expense.category::text)), v_expense.category, new.amount_minor, v_expense.amount_minor, v_expense.currency);
  return new;
end;
$$;

notify pgrst, 'reload schema';
