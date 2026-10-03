-- Recurring rule lifecycle: start/end dates and per-occurrence skips.

alter table public.recurring_rule
  add column if not exists start_date date,
  add column if not exists end_date date,
  add column if not exists skipped_dates date[] not null default '{}';

update public.recurring_rule
set start_date = next_occurrence
where start_date is null;

alter table public.recurring_rule
  alter column start_date set not null;
