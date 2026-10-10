# New York Penn track checker

NJ Transit posts a Penn departure's track about nine minutes before it
leaves. This Supabase project calls it sooner: every minute it reads NJ
Transit's RailData API (the registered developer API behind DepartureVision)
and keeps, for every NJ Transit departure on the Penn board, a call on its
track with a probability, until the board posts the real one. Glass Rail
shows that call, small and light, beside the track.

Three sources, in the order they are trusted:

1. **Signal**: `getVehicleData` gives every moving train's signalling track
   circuit. At Penn's interlockings (A and JO) the circuit names the platform:
   `platform = 22 - n`, where `n` follows `AJO` (`JO-AJO13ATK` is 9) or is
   every digit but the last after `-A` (`AA-A190TK` is 3). Credit for the
   rule: [dknowles2/ha-njtransit](https://github.com/dknowles2/ha-njtransit)
   (Apache-2.0), which held it at 229 of 231 board postings.
2. **Berth**: some board rows carry a fixed coordinate for the platform the
   train waits at before the track is posted. The checker learns which
   coordinate means which track from its own postings (8 or more at 95%).
3. **History**: for a train with no live signal, how often each track served
   this train, its line at that time of day and every departure, over 60
   days, ruling out tracks other trains around the same time already hold.
   This is the weak one, so its probabilities are low and honest.

Every call is scored against the board when the track posts
(`penn_scores`): a signal or berth call shows its own measured hit rate over
the last 14 days (starting from 19 in 20), and a history call shows the
model's probability.

## Pieces

| | |
|---|---|
| `migrations/` | Tables (`penn_departures`, `penn_sightings`, `penn_polls`, `penn_config`), the decoder, the codebook and scores views, the history guess, `penn_ingest()` (one poll) and `penn_board()` (what the app reads). Applied in order. |
| `functions/penn-poll` | Called by pg_cron every minute with the poll secret; reads RailData's Penn board (`getTrainSchedule19Rec`) and vehicle feed, and hands both to `penn_ingest()`. Keeps the RailData token for 20 hours and asks for a new one at most once every 30 minutes, six times a day (RailData allows ten). |
| `functions/penn-tracks` | Public, read-only: `GET` returns `penn_board()`. This is what the app calls. |
| `setup/penn_cron.sql` | The every-minute schedule, run once after the migrations. |
| `tests/penn_ingest_test.sql` | Two simulated polls inside a block that raises its findings, so nothing is kept. |

## Setting it up

1. Apply `migrations/` in order, then run `setup/penn_cron.sql`.
2. Deploy both functions with JWT verification off: `penn-poll` checks the
   poll secret itself, and `penn-tracks` is public.
3. Add the RailData developer login as Edge Function secrets, `NJT_USERNAME`
   and `NJT_PASSWORD` (Project Settings, Edge Functions, Secrets). They are
   never in this repo. Until they are set, each poll records "no NJ Transit
   credentials yet" in `penn_polls` and the app shows no calls.

## Checking on it

```sql
select * from penn_polls order by polled_at desc limit 5;   -- is it polling?
select * from penn_scores;                                  -- how is each source doing?
select * from penn_codebook where total >= 8 order by kind, value;
```
