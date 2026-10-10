-- Glass Rail's New York Penn track checker, part 5: a history guess needs
-- at least 2 departures of the train or 6 of its slot, counted as
-- departures. Part 1 compared those floors against recency-weighted sums,
-- where three weekly departures add up to only 1.6.

-- The history guess for a departure with no live signal: how often each
-- track has served this train, this line at this time of day, and every NJ
-- Transit departure, on the same kind of day over 60 days (recent days
-- count more), each level shrunk toward the next; tracks other departures
-- around the same time already hold are ruled out.
create or replace function public.penn_history_guess(
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
    select sum(w) filter (where train_id = p_train) as w_train,
           sum(w) filter (where line_code = p_line
             and abs(dep_minute - (select dep_minute from target)) <= 60) as w_slot,
           sum(w) as w_all,
           count(*) filter (where train_id = p_train) as k_train,
           count(*) filter (where line_code = p_line
             and abs(dep_minute - (select dep_minute from target)) <= 60) as k_slot
    from obs
  ), shrunk as (
    select c.track,
           (c.c_all + 1) / (coalesce(t.w_all, 0) + 21) as p_all,
           c.c_slot, c.c_train,
           coalesce(t.w_slot, 0) as w_slot, coalesce(t.w_train, 0) as w_train,
           t.k_train, t.k_slot
    from counts c, totals t
  ), levels as (
    select track, k_train, k_slot,
           (c_train + 4 * ((c_slot + 8 * p_all) / (w_slot + 8))) / (w_train + 4) as p
    from shrunk
  )
  -- n_train and n_slot are how many departures each level saw, unweighted:
  -- the poll asks for at least 2 of this train or 6 of its slot.
  select track, (p / sum(p) over ())::real as prob, k_train::real, k_slot::real
  from levels
  order by p desc
  limit 1
$$;
