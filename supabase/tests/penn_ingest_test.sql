-- Exercises penn_ingest() on two simulated polls and reports what it did.
--
-- Everything runs inside one DO block that ends by raising its findings as
-- an error, so the transaction rolls back and no test row is left behind to
-- skew the history, the codebook or the scores. Run it with the SQL editor
-- or the Supabase MCP; read the result from the error message.
--
-- The scene, relative to now (t0):
--   6261 at t0+25, no track yet, its set on circuit AA-A132TK (track 9);
--        the next poll posts track 9.
--   6299 at t0+40, no track, used track 7 on the same weekday for 3 weeks.
--   6301 at t0+50, no track, used track 5 for 3 weeks, but 6303 at t0+45
--        holds track 5 on the board now, so 5 is ruled out.
--   A177 (Amtrak) at t0+10 on track 12, and an inbound 6672 on a route
--        circuit, which must change nothing.
do $test$
declare
  t0 timestamptz := date_trunc('minute', now());
  fmt constant text := 'DD-Mon-YYYY HH12:MI:SS AM';
  vehicles jsonb;
  board1 jsonb;
  board2 jsonb;
  result jsonb;
  stamp text;
begin
  -- Three weeks of history for 6299 (track 7) and 6301 (track 5).
  for i in 1..3 loop
    insert into public.penn_departures (train_id, sched_dep, operator, line_code,
      first_seen_at, last_seen_at, track, posted_track)
    values
      ('6299', t0 + interval '40 minutes' - make_interval(days => 7 * i), 'NJT', 'MC',
       t0 - make_interval(days => 7 * i), t0 - make_interval(days => 7 * i), '7', '7'),
      ('6301', t0 + interval '50 minutes' - make_interval(days => 7 * i), 'NJT', 'MC',
       t0 - make_interval(days => 7 * i), t0 - make_interval(days => 7 * i), '5', '5');
  end loop;

  vehicles := jsonb_build_array(
    jsonb_build_object('ID', '6261', 'ICS_TRACK_CKT', 'AA-A132TK', 'NEXT_STOP', 'Secaucus',
      'SCHED_DEP_TIME', to_char((t0 + interval '25 minutes') at time zone 'America/New_York', fmt)),
    jsonb_build_object('ID', '6672', 'ICS_TRACK_CKT', 'AA-79N', 'NEXT_STOP', 'New York',
      'SCHED_DEP_TIME', to_char((t0 - interval '30 minutes') at time zone 'America/New_York', fmt)));

  board1 := jsonb_build_object('STATION_2CHAR', 'NY', 'ITEMS', jsonb_build_array(
    jsonb_build_object('TRAIN_ID', 'A177', 'TRACK', '12', 'LINECODE', 'AM',
      'SCHED_DEP_DATE', to_char((t0 + interval '10 minutes') at time zone 'America/New_York', fmt)),
    jsonb_build_object('TRAIN_ID', '6261', 'TRACK', '', 'LINECODE', 'MC', 'STATUS', ' ', 'SEC_LATE', '0',
      'SCHED_DEP_DATE', to_char((t0 + interval '25 minutes') at time zone 'America/New_York', fmt)),
    jsonb_build_object('TRAIN_ID', '6299', 'TRACK', '', 'LINECODE', 'MC',
      'SCHED_DEP_DATE', to_char((t0 + interval '40 minutes') at time zone 'America/New_York', fmt)),
    jsonb_build_object('TRAIN_ID', '6303', 'TRACK', '5', 'LINECODE', 'MC',
      'SCHED_DEP_DATE', to_char((t0 + interval '45 minutes') at time zone 'America/New_York', fmt)),
    jsonb_build_object('TRAIN_ID', '6301', 'TRACK', '', 'LINECODE', 'MC',
      'SCHED_DEP_DATE', to_char((t0 + interval '50 minutes') at time zone 'America/New_York', fmt))));

  -- The next poll: 6261 is posted to track 9.
  board2 := jsonb_set(board1, '{ITEMS,1,TRACK}', '"9"');

  perform public.penn_ingest(board1, vehicles, t0, 5);
  perform public.penn_ingest(board2, vehicles, t0 + interval '1 minute', 5);

  select jsonb_build_object(
    'departures', (select jsonb_object_agg(d.train_id, jsonb_build_object(
        'track', d.track, 'posted_at', d.posted_at,
        'pred', d.pred_track, 'prob', d.pred_prob, 'source', d.pred_source,
        'scored', d.scored_track, 'scored_source', d.scored_source,
        'scored_since', d.scored_since))
      from public.penn_departures d where d.last_seen_at >= t0),
    'sightings', (select jsonb_agg(s.kind || ':' || s.value || '@' || s.train_id)
      from public.penn_sightings s),
    'codebook', (select jsonb_agg(c) from public.penn_codebook c),
    'scores', (select jsonb_agg(s) from public.penn_scores s),
    'board', public.penn_board(t0 + interval '1 minute')
  ) into result;

  raise exception 'PENN TEST (rolled back): %', result;
end
$test$;
