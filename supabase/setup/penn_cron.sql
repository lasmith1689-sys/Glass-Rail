-- The every-minute poll of New York Penn (run once, after the migrations, in
-- the SQL editor; running it again replaces the job). It calls the penn-poll
-- edge function with the poll secret, which never leaves the database.
select cron.schedule(
  'penn-poll',
  '* * * * *',
  $job$
  select net.http_post(
    url := 'https://hhzizoiftyuvqgscyqxh.supabase.co/functions/v1/penn-poll',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-poll-secret', (select value from public.penn_config where key = 'poll_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000)
  $job$
);
