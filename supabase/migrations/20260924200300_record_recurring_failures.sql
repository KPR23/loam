-- A rule that cannot generate (for example a participant who is no longer
-- connected) stays due and is retried, but the owner now sees why.
alter table public.recurring_rule add column failure text;
alter table public.recurring_rule add column failed_at timestamptz;

create or replace function private.materialize_rules(p_rule_ids uuid[],p_through date) returns integer
language plpgsql set search_path='' as $$
declare v_id uuid; total integer:=0;
begin
  foreach v_id in array coalesce(p_rule_ids,'{}') loop
    begin
      total:=total+private.materialize_recurring_rule(v_id,p_through);
      update public.recurring_rule set failure=null,failed_at=null where id=v_id and failure is not null;
    exception when others then
      raise warning 'Recurring rule % was not materialized: %',v_id,sqlerrm;
      update public.recurring_rule set failure=sqlerrm,failed_at=now() where id=v_id;
    end;
  end loop;
  return total;
end $$;

notify pgrst,'reload schema';
