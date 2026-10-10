-- Glass Rail's New York Penn track checker.
--
-- NJ Transit posts a Penn departure's track about nine minutes before it
-- leaves. Its RailData API says more, sooner: the signalling system's track
-- circuit for every moving train (getVehicleData), and on some board rows a
-- fixed coordinate for the platform the train is waiting at
-- (getTrainSchedule19Rec). Every minute pg_cron asks the penn-poll function
-- to read both and hand them to penn_ingest(), which keeps one row per
-- departure: the track the board posted, what the checker predicts until it
-- does, and what was showing when it did, so every source is scored against
-- the board. penn_board() is what the app reads, through penn-tracks.
--
-- Nothing here is readable without the service role: every table has row
-- level security and no policies, and the functions are revoked from the
-- public roles. The functions run as their owner for the edge functions.

-- Private settings: the secret pg_cron sends with each poll, and the RailData
-- token with its mint attempts (getToken allows ten a day).
create table public.penn_config (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
alter table public.penn_config enable row level security;

insert into public.penn_config (key, value)
values ('poll_secret', encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

-- One row per departure the Penn board has listed.
create table public.penn_departures (
  train_id text not null,
  sched_dep timestamptz not null,
  operator text not null,                 -- NJT, or AMTRAK for A-numbered rows
  line text,
  line_code text,
  destination text,
  first_seen_at timestamptz not null,
  last_seen_at timestamptz not null,
  seen_without_track boolean not null default false,
  track text,                             -- the board's track, latest
  posted_track text,                      -- the first track the board showed
  posted_at timestamptz,                  -- when, if seen without one first
  status text,
  sec_late integer,
  berth_value text,                       -- the board's platform coordinate
  pred_track text,                        -- the checker's call, until posted
  pred_prob real,
  pred_source text,                       -- signal | berth | history
  pred_since timestamptz,                 -- when this call first showed
  scored_track text,                      -- the call showing when it posted
  scored_prob real,
  scored_source text,                     -- signal | berth | history | none
  scored_since timestamptz,
  primary key (train_id, sched_dep)
);
create index penn_departures_sched_dep on public.penn_departures (sched_dep);
create index penn_departures_last_seen on public.penn_departures (last_seen_at);
alter table public.penn_departures enable row level security;

-- Every track circuit at Penn's interlockings (AA, JO) a train was seen on,
-- and every board coordinate, by train: what the codebook learns from.
create table public.penn_sightings (
  kind text not null,                     -- circuit | berth
  value text not null,
  train_id text not null,
  sched_dep timestamptz not null,         -- the train's scheduled departure
  next_stop text,
  first_at timestamptz not null,
  last_at timestamptz not null,
  primary key (kind, value, train_id, sched_dep)
);
create index penn_sightings_train on public.penn_sightings (train_id, sched_dep);
alter table public.penn_sightings enable row level security;

-- One row per poll: the checker's health.
create table public.penn_polls (
  polled_at timestamptz primary key,
  ok boolean not null,
  board_rows integer,
  vehicles integer,
  millis integer,
  note text
);
alter table public.penn_polls enable row level security;

-- RailData's times: "14-Sep-2026 09:32:00 PM", Eastern.
create function public.penn_time(s text) returns timestamptz
language sql stable set search_path = '' as $$
  select case when s ~ '^\d{1,2}-[A-Za-z]{3}-\d{4} \d{1,2}:\d{2}:\d{2} [AP]M$'
    then (pg_catalog.to_timestamp(s, 'DD-Mon-YYYY HH12:MI:SS AM')::timestamp)
         at time zone 'America/New_York' end
$$;

create function public.penn_int(s text) returns integer
language sql immutable set search_path = '' as $$
  select case when trim(s) ~ '^-?\d{1,9}$' then trim(s)::integer end
$$;

-- The platform a Penn track circuit stands for. Penn's interlockings number
-- the platform tracks from the other side, meeting the signs at 11:
-- platform = 22 - n, where n follows "AJO" (JO-AJO13ATK, AA-AAJO11ATK) or
-- is every digit but the last after "-A" (AA-A190TK is 19, AA-A71TK is 7).
-- Found by dknowles2/ha-njtransit (Apache-2.0); the codebook below checks it
-- against our own board postings and overrides it where they disagree.
create function public.penn_circuit_track(circuit text) returns text
language sql immutable set search_path = '' as $$
  select case when n between 1 and 21 then (22 - n)::text end
  from (
    select coalesce(
      substring(upper(circuit) from 'AJO(\d{1,2})[AB]?TK$'),
      substring(upper(circuit) from '-A(\d{1,2})\dTK$')
    )::integer as n
  ) s
  where upper(circuit) ~ '^(AA|JO)-'
$$;

-- What each circuit and coordinate has meant: every sighting before the
-- train's departure time, labelled with the track the board gave it, one
-- vote per departure.
create view public.penn_codebook with (security_invoker = true) as
with votes as (
  select distinct s.kind, s.value, d.train_id, d.sched_dep, d.track
  from public.penn_sightings s
  join public.penn_departures d using (train_id, sched_dep)
  where d.track is not null
    and d.sched_dep > now() - interval '90 days'
    and s.first_at < d.sched_dep + make_interval(secs => greatest(coalesce(d.sec_late, 0), 0))
), counts as (
  select kind, value, track, count(*) as n
  from votes group by kind, value, track
)
select kind, value, track, n,
       sum(n) over (partition by kind, value) as total,
       n::real / sum(n) over (partition by kind, value) as purity
from counts;

-- How each source has done over the last 14 days: what was showing when the
-- board posted, against the board's final track.
create view public.penn_scores with (security_invoker = true) as
select scored_source as source,
       count(*) as n,
       count(*) filter (where scored_track = track) as hits,
       percentile_cont(0.5) within group (
         order by extract(epoch from (sched_dep - scored_since)) / 60
       ) filter (where scored_track = track) as median_lead_minutes
from public.penn_departures
where operator = 'NJT' and scored_source is not null and track is not null
  and sched_dep > now() - interval '14 days'
group by scored_source;

-- A source's probability: its measured hit rate over 14 days, starting from
-- 19 in 20 until it has a record of its own.
create function public.penn_source_prob(p_source text) returns real
language sql stable set search_path = '' as $$
  select ((coalesce(sum(hits), 0) + 19)::real / (coalesce(sum(n), 0) + 20))
  from public.penn_scores where source = p_source
$$;

-- The history guess for a departure with no live signal: how often each
-- track has served this train, this line at this time of day, and every NJ
-- Transit departure, on the same kind of day over 60 days (recent days
-- count more), each level shrunk toward the next; tracks other departures
-- around the same time already hold are ruled out.
create function public.penn_history_guess(
  p_train text, p_line text, p_sched timestamptz, p_exclude text[]
) returns table (track text, prob real, n_train real, n_slot real)
language sql stable set search_path = '' as $$
  with target as (
    select extract(isodow from p_sched at time zone 'America/New_York') >= 6 as weekend,
           extract(hour from p_sched at time zone 'America/New_York') * 60
             + extract(minute from p_sched at time zone 'America/New_York') as dep_minute
  ), obs as (
    select d.train_id, d.line_code, d.track,
           exp(-extract(epoch from (p_sched - d.sched_dep)) / 86400.0 / 21.0) as w,
           extract(hour from d.sched_dep at time zone 'America/New_York') * 60
             + extract(minute from d.sched_dep at time zone 'America/New_York') as dep_minute
    from public.penn_departures d, target t
    where d.operator = 'NJT' and d.track ~ '^\d{1,2}$'
      and d.sched_dep < p_sched - interval '1 minute'
      and d.sched_dep > p_sched - interval '60 days'
      and (extract(isodow from d.sched_dep at time zone 'America/New_York') >= 6) = t.weekend
  ), candidates as (
    select g::text as track from generate_series(1, 21) g
    where not (g::text = any (coalesce(p_exclude, '{}')))
  ), counts as (
    select c.track,
           coalesce(sum(o.w) filter (where o.train_id = p_train), 0) as c_train,
           coalesce(sum(o.w) filter (where o.line_code = p_line
             and abs(o.dep_minute - (select dep_minute from target)) <= 60), 0) as c_slot,
           coalesce(sum(o.w), 0) as c_all
    from candidates c left join obs o on o.track = c.track
    group by c.track
  ), totals as (
    select sum(w) filter (where train_id = p_train) as n_train,
           sum(w) filter (where line_code = p_line
             and abs(dep_minute - (select dep_minute from target)) <= 60) as n_slot,
           sum(w) as n_all
    from obs
  ), shrunk as (
    select c.track,
           (c.c_all + 1) / (coalesce(t.n_all, 0) + 21) as p_all,
           c.c_slot, c.c_train,
           coalesce(t.n_slot, 0) as n_slot, coalesce(t.n_train, 0) as n_train
    from counts c, totals t
  ), levels as (
    select track, n_train, n_slot,
           (c_train + 4 * ((c_slot + 8 * p_all) / (n_slot + 8))) / (n_train + 4) as p
    from shrunk
  )
  select track, (p / sum(p) over ())::real as prob, n_train::real, n_slot::real
  from levels
  order by p desc
  limit 1
$$;

