-- Glass Rail's New York Penn track checker: history calls show their
-- measured odds.
--
-- A history call shows the model's probability, and in its first live week
-- those ran high: history calls showed 38% on average and came right 15
-- times in 54 (28%). penn_history_scale() measures the history calls scored
-- in the last 14 days, hits against the probabilities they were called at,
-- and penn_board() shows each history call's probability times that scale.
--
-- The scale only ever lowers a history call (between half and as is), and
-- five calls' worth of agreement is assumed until the record says otherwise.
-- The scored probability stays the model's own, so the scale is always
-- measured against the model, never against itself.

create function public.penn_history_scale(p_now timestamptz default now()) returns real
language sql stable set search_path = '' as $$
  select greatest(0.5, least(1.0,
           (coalesce(sum((d.scored_track = d.posted_track)::int), 0) + 5)::real
         / (coalesce(sum(d.scored_prob), 0) + 5)))::real
  from public.penn_departures d
  where d.operator = 'NJT' and d.scored_source = 'history'
    and d.posted_track is not null and d.scored_prob is not null
    and d.sched_dep > p_now - interval '14 days' and d.sched_dep <= p_now
$$;
revoke all on function public.penn_history_scale(timestamptz) from public, anon, authenticated;

-- penn_board() as before, with history calls at their measured odds.
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
          'probability', round((d.pred_prob * case when d.pred_source = 'history'
            then (select public.penn_history_scale(p_now)) else 1 end)::numeric, 3),
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
