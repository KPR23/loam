-- People who leave an email on the website to hear when Loam launches.
-- Lives in private so the anon key can only reach it through join_waitlist.
create table private.waitlist_signup (
  email text primary key check (email = lower(email) and length(email) <= 254 and email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  source text check (length(source) <= 64),
  created_at timestamptz not null default now()
);
revoke all on private.waitlist_signup from public, anon, authenticated;

-- Joining twice succeeds quietly, so the form never reveals who already signed up.
create function public.join_waitlist(p_email text, p_source text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare v_email text := lower(btrim(p_email));
begin
  if v_email is null or length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'Invalid email' using errcode = '22023';
  end if;
  insert into private.waitlist_signup(email, source)
  values (v_email, left(nullif(btrim(p_source), ''), 64))
  on conflict (email) do nothing;
end;
$$;
revoke all on function public.join_waitlist(text, text) from public, anon, authenticated;
grant execute on function public.join_waitlist(text, text) to anon, authenticated;
