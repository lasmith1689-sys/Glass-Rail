-- Glass Rail's New York Penn track checker, part 6: what the every-minute
-- poll runs on. pg_cron fires it and pg_net makes the call to penn-poll;
-- the schedule itself names the project, so it lives in
-- supabase/setup/penn_cron.sql rather than here.
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;
