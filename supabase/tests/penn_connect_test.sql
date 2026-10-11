-- Exercises connecting NJ Transit from the app: setup codes, the login kept
-- in Vault, and the checker's state in penn_board().
--
-- Everything runs inside one DO block that ends by raising its findings as
-- an error, so the transaction rolls back: no code, login or token is left
-- behind. Run it with the SQL editor or the Supabase MCP; read the result
-- from the error message. Expected (none=skipped once a code was issued):
--   none=none alphabet_ok=t wrong=wrong misses=1 ok=ok user=test-user
--   pass_ok=t token_value=test-token token_at_set=t used=used
--   checker={"at": ..., "state": "starting"} locked=locked expired=expired

do $$
declare
  code text; code2 text; code3 text;
  r_wrong text; r_ok text; r_used text; r_locked text; r_expired text; r_none text;
  misses int;
  login jsonb;
  checker jsonb;
  token jsonb;
  alphabet_ok boolean;
begin
  -- Before any code is issued (skipped once one has been).
  r_none := case when exists (select 1 from public.penn_config where key = 'connect_code')
                 then 'skipped' else public.penn_check_code('ABCDEF') end;

  -- A code, a wrong try, then the right one typed loosely.
  code := public.penn_new_code();
  alphabet_ok := code ~ '^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{6}$';
  r_wrong := public.penn_check_code('zzzzzz');
  select (value::jsonb->>'misses')::int into misses from public.penn_config where key = 'connect_code';
  r_ok := public.penn_check_code(lower(substr(code, 1, 3)) || '-' || substr(code, 4, 3) || ' ');

  -- What penn-connect does once RailData accepts the login.
  perform public.penn_finish_connect('test-user', 'test-pass', 'test-token');
  login := public.penn_login();
  token := (select value::jsonb from public.penn_config where key = 'raildata_token');
  r_used := public.penn_check_code(code);
  checker := public.penn_board()->'checker';

  -- Eight wrong tries retire a code; so does its fourteenth day.
  code2 := public.penn_new_code();
  for i in 1..8 loop perform public.penn_check_code('zzzzzz'); end loop;
  r_locked := public.penn_check_code(code2);
  code3 := public.penn_new_code();
  update public.penn_config
     set value = jsonb_set(value::jsonb, '{expires}', '"2020-01-01T00:00:00Z"')::text
   where key = 'connect_code';
  r_expired := public.penn_check_code(code3);

  raise exception 'RESULT none=% alphabet_ok=% wrong=% misses=% ok=% user=% pass_ok=% token_value=% token_at_set=% used=% checker=% locked=% expired=%',
    r_none, alphabet_ok, r_wrong, misses, r_ok, login->>'username', (login->>'password') = 'test-pass',
    token->>'value', token->>'at' is not null, r_used, checker, r_locked, r_expired;
end $$;
