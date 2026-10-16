-- Exercises history calls at their measured odds: penn_history_scale() and
-- the probability penn_board() shows.
--
-- Everything runs inside one DO block that ends by raising its findings as
-- an error, so the transaction rolls back. The made-up departures sit a year
-- and more ahead, where no real departure is. Expected:
--   empty=1 measured=0.778 history_shown=0.311 signal_shown=0.970
--   floor=0.5 ceiling=1

do $$
declare
  t0 timestamptz := now() + interval '400 days';
  t1 timestamptz := now() + interval '800 days';
  s_empty real; s_measured real; s_floor real; s_ceiling real;
  board jsonb;
  history_shown numeric; signal_shown numeric;
begin
  -- No history calls scored yet: shown as called.
  s_empty := public.penn_history_scale(t0);

  -- Ten history calls at 40%, two right: (2 + 5) / (4 + 5).
  insert into public.penn_departures (train_id, sched_dep, operator, first_seen_at, last_seen_at,
    seen_without_track, track, posted_track, posted_at, scored_track, scored_prob, scored_source, scored_since)
  select 'T' || g, t0 - g * interval '1 hour', 'NJT', t0 - interval '1 day', t0 - interval '1 day',
         true, '5', '5', t0 - g * interval '1 hour',
         case when g <= 2 then '5' else '6' end, 0.4, 'history', t0 - g * interval '2 hours'
  from generate_series(1, 10) g;
  s_measured := public.penn_history_scale(t0);

  -- What the app is shown: the history call scaled, the signal call as is.
  insert into public.penn_departures (train_id, sched_dep, operator, first_seen_at, last_seen_at,
    seen_without_track, pred_track, pred_prob, pred_source, pred_since)
  values ('H1', t0 + interval '30 minutes', 'NJT', t0, t0, true, '7', 0.4, 'history', t0),
         ('S1', t0 + interval '40 minutes', 'NJT', t0, t0, true, '9', 0.97, 'signal', t0);
  board := public.penn_board(t0);
  select (d -> 'prediction' ->> 'probability')::numeric into history_shown
    from jsonb_array_elements(board -> 'departures') d where d ->> 'trainId' = 'H1';
  select (d -> 'prediction' ->> 'probability')::numeric into signal_shown
    from jsonb_array_elements(board -> 'departures') d where d ->> 'trainId' = 'S1';

  -- Twenty more misses at 90%: never below half.
  insert into public.penn_departures (train_id, sched_dep, operator, first_seen_at, last_seen_at,
    seen_without_track, track, posted_track, posted_at, scored_track, scored_prob, scored_source, scored_since)
  select 'M' || g, t0 - g * interval '20 minutes', 'NJT', t0 - interval '1 day', t0 - interval '1 day',
         true, '5', '5', t0 - g * interval '20 minutes', '6', 0.9, 'history', t0 - g * interval '1 hour'
  from generate_series(1, 20) g;
  s_floor := public.penn_history_scale(t0);

  -- Eight right of ten at 20%: never raised.
  insert into public.penn_departures (train_id, sched_dep, operator, first_seen_at, last_seen_at,
    seen_without_track, track, posted_track, posted_at, scored_track, scored_prob, scored_source, scored_since)
  select 'U' || g, t1 - g * interval '1 hour', 'NJT', t1 - interval '1 day', t1 - interval '1 day',
         true, '5', '5', t1 - g * interval '1 hour',
         case when g <= 8 then '5' else '6' end, 0.2, 'history', t1 - g * interval '2 hours'
  from generate_series(1, 10) g;
  s_ceiling := public.penn_history_scale(t1);

  raise exception 'RESULT empty=% measured=% history_shown=% signal_shown=% floor=% ceiling=%',
    s_empty, round(s_measured::numeric, 3), history_shown, signal_shown, s_floor, s_ceiling;
end $$;
