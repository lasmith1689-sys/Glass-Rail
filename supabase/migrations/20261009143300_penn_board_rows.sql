-- Glass Rail's New York Penn track checker, part 4: the poll reads the board
-- through penn_board_rows() rather than a temporary table, so two polls can
-- run in one transaction (the tests do).

-- The board's rows as RailData sent them: one per departure.
create function public.penn_board_rows(p_items jsonb)
returns table (train_id text, sched_dep timestamptz, track text, status text,
               sec_late integer, line text, line_code text, destination text, berth text)
language sql stable set search_path = '' as $$
  select distinct on (r.train_id, r.sched_dep) r.*
  from (
    select nullif(trim(i ->> 'TRAIN_ID'), '') as train_id,
           public.penn_time(i ->> 'SCHED_DEP_DATE') as sched_dep,
           nullif(trim(i ->> 'TRACK'), '') as track,
           nullif(trim(i ->> 'STATUS'), '') as status,
           public.penn_int(i ->> 'SEC_LATE') as sec_late,
           nullif(trim(i ->> 'LINE'), '') as line,
           nullif(trim(i ->> 'LINECODE'), '') as line_code,
           nullif(trim(i ->> 'DESTINATION'), '') as destination,
           case when nullif(trim(i ->> 'GPSLATITUDE'), '') is not null
                 and nullif(trim(i ->> 'GPSLONGITUDE'), '') is not null
             then trim(i ->> 'GPSLATITUDE') || ',' || trim(i ->> 'GPSLONGITUDE') end as berth
    from jsonb_array_elements(public.penn_list(p_items)) i
  ) r
  where r.train_id is not null and r.sched_dep is not null
$$;

-- One poll: the board and the vehicle feed, as RailData sent them.
create or replace function public.penn_ingest(
  p_board jsonb, p_vehicles jsonb, p_polled_at timestamptz default now(), p_millis integer default null
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  board_items jsonb := public.penn_list(case jsonb_typeof(p_board)
    when 'array' then p_board -> 0 -> 'ITEMS' else p_board -> 'ITEMS' end);
  vehicle_items jsonb := public.penn_list(p_vehicles);
  board_count integer;
  signal_prob real := public.penn_source_prob('signal');
  berth_prob real := public.penn_source_prob('berth');
begin
  select count(*) into board_count from public.penn_board_rows(board_items);

  -- 1. The board. A departure's first posted track scores whatever the
  -- checker was showing for it until this poll.
  insert into public.penn_departures as d (
    train_id, sched_dep, operator, line, line_code, destination,
    first_seen_at, last_seen_at, seen_without_track, track, posted_track,
    status, sec_late, berth_value)
  select b.train_id, b.sched_dep,
         case when b.train_id ~* '^A' then 'AMTRAK' else 'NJT' end,
         b.line, b.line_code, b.destination, p_polled_at, p_polled_at,
         b.track is null, b.track, b.track, b.status, b.sec_late, b.berth
  from public.penn_board_rows(board_items) b
  on conflict (train_id, sched_dep) do update set
    last_seen_at = excluded.last_seen_at,
    line = coalesce(excluded.line, d.line),
    line_code = coalesce(excluded.line_code, d.line_code),
    destination = coalesce(excluded.destination, d.destination),
    status = excluded.status,
    sec_late = excluded.sec_late,
    berth_value = excluded.berth_value,
    seen_without_track = d.seen_without_track or excluded.track is null,
    track = coalesce(excluded.track, d.track),
    posted_track = coalesce(d.posted_track, excluded.track),
    posted_at = case when d.posted_track is null and excluded.track is not null
      and d.seen_without_track then excluded.last_seen_at else d.posted_at end,
    scored_track = case when d.posted_track is null and excluded.track is not null
      and d.seen_without_track then d.pred_track else d.scored_track end,
    scored_prob = case when d.posted_track is null and excluded.track is not null
      and d.seen_without_track then d.pred_prob else d.scored_prob end,
    scored_source = case when d.posted_track is null and excluded.track is not null
      and d.seen_without_track then coalesce(d.pred_source, 'none') else d.scored_source end,
    scored_since = case when d.posted_track is null and excluded.track is not null
      and d.seen_without_track then d.pred_since else d.scored_since end;

  -- 2. Board coordinates as the board shows them now, labelled later by the
  -- track it posts.
  insert into public.penn_sightings as s (kind, value, train_id, sched_dep, first_at, last_at)
  select 'berth', b.berth, b.train_id, b.sched_dep, p_polled_at, p_polled_at
  from public.penn_board_rows(board_items) b
  where b.berth is not null
  on conflict (kind, value, train_id, sched_dep) do update set last_at = excluded.last_at;

  -- 3. Track circuits at Penn's interlockings, for every train on one, on
  -- the board yet or not: a set can reach its platform before the board
  -- lists its train, and drops out of the feed once it stops moving.
  insert into public.penn_sightings as s (kind, value, train_id, sched_dep, next_stop, first_at, last_at)
  select distinct on (v.train_id, v.sched_dep, v.circuit)
         'circuit', v.circuit, v.train_id, v.sched_dep, v.next_stop, p_polled_at, p_polled_at
  from (
    select nullif(trim(x ->> 'ID'), '') as train_id,
           public.penn_time(x ->> 'SCHED_DEP_TIME') as sched_dep,
           upper(nullif(trim(x ->> 'ICS_TRACK_CKT'), '')) as circuit,
           nullif(trim(x ->> 'NEXT_STOP'), '') as next_stop
    from jsonb_array_elements(vehicle_items) x
  ) v
  where v.train_id is not null and v.sched_dep is not null
    and v.circuit ~ '^(AA|JO)-'
  on conflict (kind, value, train_id, sched_dep) do update set
    last_at = excluded.last_at, next_stop = excluded.next_stop;

  -- 4. A call for every NJ Transit departure on the board without a track:
  -- its latest circuit if that decodes, else its board coordinate if that
  -- decodes, else history. A posted track ends the call.
  with pending as (
    select d.train_id, d.sched_dep, d.line_code, d.berth_value
    from public.penn_departures d
    where d.last_seen_at = p_polled_at and d.operator = 'NJT' and d.track is null
  ), book as (
    -- Each learned value's leading track.
    select distinct on (kind, value) kind, value, track, total, purity
    from public.penn_codebook
    order by kind, value, n desc
  ), circuit as (
    select distinct on (s.train_id, s.sched_dep) s.train_id, s.sched_dep, s.value
    from public.penn_sightings s join pending p using (train_id, sched_dep)
    where s.kind = 'circuit'
    order by s.train_id, s.sched_dep, s.last_at desc, s.first_at desc
  ), live as (
    -- Learned from at least eight departures at 95% or better; for a track
    -- circuit, the formula until eight departures have had their say.
    select p.train_id, p.sched_dep, p.line_code,
           case when cb.total >= 8 and cb.purity >= 0.95 then cb.track
                when coalesce(cb.total, 0) < 8 then public.penn_circuit_track(c.value)
           end as signal_track,
           case when bb.total >= 8 and bb.purity >= 0.95 then bb.track end as berth_track
    from pending p
    left join circuit c using (train_id, sched_dep)
    left join book cb on cb.kind = 'circuit' and cb.value = c.value
    left join book bb on bb.kind = 'berth' and bb.value = p.berth_value
  ), claimed as (
    -- Tracks the board or a live signal gives other departures within 15
    -- minutes either side: ruled out of a history guess.
    select l.train_id, l.sched_dep,
           array_agg(distinct x.track) filter (where x.track is not null) as tracks
    from live l
    left join lateral (
      select b.track from public.penn_board_rows(board_items) b
      where b.track is not null
        and abs(extract(epoch from (b.sched_dep - l.sched_dep))) <= 900
      union all
      select coalesce(o.signal_track, o.berth_track) from live o
      where (o.train_id, o.sched_dep) <> (l.train_id, l.sched_dep)
        and abs(extract(epoch from (o.sched_dep - l.sched_dep))) <= 900
    ) x on true
    group by l.train_id, l.sched_dep
  ), calls as (
    select l.train_id, l.sched_dep,
           coalesce(l.signal_track, l.berth_track, h.track) as track,
           case when l.signal_track is not null then signal_prob
                when l.berth_track is not null then berth_prob
                else h.prob end as prob,
           case when l.signal_track is not null then 'signal'
                when l.berth_track is not null then 'berth'
                when h.track is not null then 'history' end as source
    from live l
    join claimed c using (train_id, sched_dep)
    left join lateral (
      select g.track, g.prob
      from public.penn_history_guess(l.train_id, l.line_code, l.sched_dep, c.tracks) g
      where l.signal_track is null and l.berth_track is null
        and (g.n_train >= 2 or g.n_slot >= 6)
    ) h on true
  )
  update public.penn_departures d set
    pred_track = c.track, pred_prob = c.prob, pred_source = c.source,
    pred_since = case when c.track is null then null
                      when d.pred_track is distinct from c.track then p_polled_at
                      else d.pred_since end
  from calls c
  where d.train_id = c.train_id and d.sched_dep = c.sched_dep;

  update public.penn_departures d
  set pred_track = null, pred_prob = null, pred_source = null, pred_since = null
  where d.last_seen_at = p_polled_at and d.track is not null and d.pred_track is not null;

  insert into public.penn_polls (polled_at, ok, board_rows, vehicles, millis)
  values (p_polled_at, true, board_count, jsonb_array_length(vehicle_items), p_millis)
  on conflict (polled_at) do nothing;

  return jsonb_build_object('board', board_count, 'vehicles', jsonb_array_length(vehicle_items));
end
$$;

