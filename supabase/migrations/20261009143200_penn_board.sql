-- Glass Rail's New York Penn track checker, part 3: what the app reads, and
-- who may call what. Parts 1 and 2 have the tables and the poll.

-- What the app reads: NJ Transit departures on the board now, each with its
-- posted track or the checker's call, and the checker's own record.
create function public.penn_board(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'generatedAt', p_now,
    'lastPoll', (select max(polled_at) from public.penn_polls where ok),
    'departures', coalesce((
      select jsonb_agg(jsonb_build_object(
        'trainId', d.train_id,
        'scheduled', d.sched_dep,
        'track', d.track,
        'prediction', case when d.track is null and d.pred_track is not null then jsonb_build_object(
          'track', d.pred_track,
          'probability', round(d.pred_prob::numeric, 3),
          'source', d.pred_source,
          'since', d.pred_since) end
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

revoke all on function public.penn_ingest(jsonb, jsonb, timestamptz, integer) from public, anon, authenticated;
revoke all on function public.penn_board(timestamptz) from public, anon, authenticated;
revoke all on function public.penn_history_guess(text, text, timestamptz, text[]) from public, anon, authenticated;
revoke all on function public.penn_source_prob(text) from public, anon, authenticated;
grant execute on function public.penn_ingest(jsonb, jsonb, timestamptz, integer) to service_role;
grant execute on function public.penn_board(timestamptz) to service_role;
revoke all on public.penn_codebook, public.penn_scores from anon, authenticated;
