-- These prototype tables are not used by the application anymore:
-- * repayment is the immutable, pairwise replacement for settlement
-- * connection_invitation replaces household_invite
--
-- Deliberately do not use CASCADE. If a future object still depends on either
-- legacy table, this migration must fail loudly rather than silently remove it.

drop view if exists public.v_household_balances;
drop table if exists public.settlement;
drop table if exists public.household_invite;
