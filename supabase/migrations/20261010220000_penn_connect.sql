-- Glass Rail's New York Penn track checker, part 8: connecting NJ Transit
-- from the app. The RailData login can come from Glass Rail's Settings
-- (the penn-connect function) as well as from the NJT_USERNAME and
-- NJT_PASSWORD Edge Function secrets. penn-connect needs a one-time setup
-- code (penn_new_code(), run by the project owner), has RailData accept the
-- login, then keeps it here, encrypted in Vault; penn-poll prefers it.
--
-- penn_board() also says how the checker itself is doing, for Settings.

-- A new setup code, returned once: only its SHA-256 is kept. It lasts 14
-- days, is retired by the connection it makes, and eight wrong tries retire
-- it too. Its letters leave out I, L, O, 0 and 1.
create function public.penn_new_code() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  bytes constant bytea := extensions.gen_random_bytes(6);
  code text := '';
begin
  for i in 0..5 loop
    code := code || substr(alphabet, 1 + get_byte(bytes, i) % length(alphabet), 1);
  end loop;
  insert into public.penn_config (key, value, updated_at)
  values ('connect_code', jsonb_build_object(
    'hash', encode(extensions.digest(code, 'sha256'), 'hex'),
    'expires', public.penn_utc(now() + interval '14 days'),
    'misses', 0)::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
  return code;
end $$;

-- What penn-connect makes of a code the rider typed (case, spaces and dashes
-- don't matter): ok, wrong, none, used, expired or locked. A wrong one counts.
create function public.penn_check_code(p_code text) returns text
language plpgsql volatile security definer set search_path = '' as $$
declare
  held jsonb;
begin
  select value::jsonb into held from public.penn_config where key = 'connect_code' for update;
  if held is null then return 'none'; end if;
  if held->>'used' is not null then return 'used'; end if;
  if (held->>'expires')::timestamptz < now() then return 'expired'; end if;
  if coalesce((held->>'misses')::int, 0) >= 8 then return 'locked'; end if;
  if encode(extensions.digest(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'sha256'), 'hex')
     = held->>'hash' then
    return 'ok';
  end if;
  update public.penn_config
     set value = jsonb_set(held, '{misses}', to_jsonb(coalesce((held->>'misses')::int, 0) + 1))::text,
         updated_at = now()
   where key = 'connect_code';
  return 'wrong';
end $$;

-- A login RailData has just accepted: kept encrypted in Vault, with the
-- token it earned (so the next poll needs no getToken of its own), and the
-- setup code retired.
create function public.penn_finish_connect(p_username text, p_password text, p_token text) returns void
language plpgsql volatile security definer set search_path = '' as $$
declare
  login constant text := jsonb_build_object('username', p_username, 'password', p_password)::text;
  existing uuid;
begin
  select id into existing from vault.secrets where name = 'penn_njt_login';
  if existing is null then
    perform vault.create_secret(login, 'penn_njt_login', 'NJ Transit RailData login for the Penn track checker');
  else
    perform vault.update_secret(existing, login);
  end if;
  insert into public.penn_config (key, value, updated_at) values
    ('raildata_token', jsonb_build_object('value', p_token, 'at', public.penn_utc(now()))::text, now()),
    ('login_saved', public.penn_utc(now()), now()),
    ('connect_code', jsonb_build_object('used', public.penn_utc(now()))::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
end $$;

-- The saved login, for penn-poll: {"username", "password"}, or null.
create function public.penn_login() returns jsonb
language sql stable security definer set search_path = '' as $$
  select decrypted_secret::jsonb from vault.decrypted_secrets where name = 'penn_njt_login'
$$;

-- penn_board() as before, plus the checker's own state from its latest poll:
-- ok; starting (a login was just connected); needs-login; login-refused
-- (RailData turned the saved login down); trouble (the read failed, and the
-- next minute tries again); stopped (no poll for five minutes).
create or replace function public.penn_board(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'generatedAt', public.penn_utc(p_now),
    'lastPoll', public.penn_utc((select max(polled_at) from public.penn_polls where ok)),
    'checker', (
      select jsonb_build_object(
        'state', case
          when p.polled_at < p_now - interval '5 minutes' then 'stopped'
          when p.ok then 'ok'
          when (select value::timestamptz from public.penn_config where key = 'login_saved') > p.polled_at then 'starting'
          when p.note = 'no NJ Transit credentials yet' then 'needs-login'
          when p.note like 'getToken refused%' then 'login-refused'
          else 'trouble' end,
        'at', public.penn_utc(p.polled_at))
      from (select polled_at, ok, note from public.penn_polls order by polled_at desc limit 1) p
    ),
    'departures', coalesce((
      select jsonb_agg(jsonb_build_object(
        'trainId', d.train_id,
        'scheduled', public.penn_utc(d.sched_dep),
        'track', d.track,
        'prediction', case when d.track is null and d.pred_track is not null then jsonb_build_object(
          'track', d.pred_track,
          'probability', round(d.pred_prob::numeric, 3),
          'source', d.pred_source,
          'since', public.penn_utc(d.pred_since)) end
      ) order by d.sched_dep)
      from public.penn_departures d
      where d.operator = 'NJT' and d.last_seen_at >= p_now - interval '3 minutes'
    ), '[]'),
    'record', coalesce((
      select jsonb_object_agg(s.source, jsonb_build_object(
        'n', s.n, 'hits', s.hits, 'medianLeadMinutes', round(s.median_lead_minutes::numeric, 1)))
      from public.penn_scores s
    ), '{}')
  )
$$;

revoke all on function public.penn_new_code() from public, anon, authenticated, service_role;
revoke all on function public.penn_check_code(text) from public, anon, authenticated;
revoke all on function public.penn_finish_connect(text, text, text) from public, anon, authenticated;
revoke all on function public.penn_login() from public, anon, authenticated;
grant execute on function public.penn_check_code(text) to service_role;
grant execute on function public.penn_finish_connect(text, text, text) to service_role;
grant execute on function public.penn_login() to service_role;
