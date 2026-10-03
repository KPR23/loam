-- New signatures were added alongside these instead of replacing them.
-- Edge functions call only the six-argument versions.
drop function public.accept_account_deletion(uuid,uuid,text,text,text);
drop function public.advance_account_deletion_job(uuid,text,boolean,text);
