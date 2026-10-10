-- Glass Rail's New York Penn track checker, part 7: penn_board() writes its
-- times as whole-second UTC ("2026-10-09T21:58:00Z"), the form every date
-- parser reads, rather than Postgres's microseconds and offset.

create function public.penn_utc(t timestamptz) returns text
language sql immutable set search_path = '' as $$
  select to_char(t at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')
$$;

create or replace function public.penn_board(p_now timestamptz default now()) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'generatedAt', public.penn_utc(p_now),
    'lastPoll', public.penn_utc((select max(polled_at) from public.penn_polls where ok)),
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
