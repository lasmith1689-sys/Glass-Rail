# Glass Rail

A clean, fast read on the next NJ Transit train between Watchung Avenue and Hoboken or Penn Station
NY, as a native iPhone app with Home Screen and Lock Screen widgets.

This is the SwiftUI rebuild of the Glass Rail web app (v4.2, "status intelligence"). The board logic
is a line-by-line Swift port of v4's `lib/`, and v4's whole test suite is ported with it, so the app
makes the same calls v4 made: which train leads, when it truly leaves, how late each end of the ride
is, and when to say a train has departed.

## What it shows

- **Direction by clock.** Toward the city until 2 PM Eastern, home after. The flip button overrides
  it until the clock next crosses 2 PM or midnight. The route bar shows AM or PM.
- **Hoboken / Penn toggle** (HOB / NYP), remembered, and shared with the widgets.
- **Hero card** for the next train: the true pickup time as the big number, "Originally H:MM" when
  it is late, a countdown, `DELAYED Nm`, `CANCELLED` and `TRACK CHANGED` badges ("Track 2 → 3"), and
  an "On time" chip when the board says so.
- **Pickup / Drop-off pair.** Each end resolves from its own stop in NJ Transit's live stop list, so
  a train that leaves 6 minutes late and arrives 2 late says exactly that. Each side reads "On time"
  (verified live), "Scheduled" (no live data) or "Nm late".
- **Journey dot** on the route line: the train's real position between your stops, from NJ Transit's
  per-stop departed flags, time-interpolated; the timetable is the fallback.
- **"Past X · next Y"**, which opens a sheet of every stop: past stops dimmed, the next one
  highlighted, your boarding stop and your stop tagged, "Discharge Only" notes shown.
- **Transfers** with the connecting train and its live time at the transfer station.
- **"Later this way"**: the next departures at a glance, and a sheet with every later train (true
  times, arrival, per-leg lateness, badges, track). Tap one to pin it; **"Pinned · show next"**
  releases it. A pinned train survives its own departure and stays featured until about 3 minutes
  after arrival, and is remembered for 3 hours across relaunches.
- **"Train N has departed"** for 12 seconds when the featured train leaves.
- **Freshness**: `LIVE` only for genuinely live data; `STALE` ("Data may be outdated.") after 3.5
  minutes or two failed refreshes; `SAMPLE` for the bundled fallback, which never shows delays,
  track changes or an "On time" chip.
- **No service**: when your station has no trains (the Montclair Branch runs none north of Bay Street
  on weekends), it says so and lists the next trains from Bay Street.
- Refreshes every 60 seconds, on returning to the app, with pull to refresh, and with the Refresh
  button. Nine looks in Settings, all on the same board layout:
  - From v4: Glass (the default), Midnight, Aurora, Sunset, Liquid.
  - From the September 2026 design samples: Platform (night platform, warm lights, a straight track
    running to a headlight), Ember (amber glow on graphite), Navy (deep blue with gold light) and
    Station (solid charcoal cards, amber accents, and Oswald, a condensed departure-board typeface).
  - Glass, Liquid, Platform, Ember and Navy are see-through: the cards are real iOS 26 Liquid Glass
    over a backdrop of slowly drifting light and faint rail lines, seen blurred and bent through
    each card. The drift pauses off screen and with Reduce Motion; with Reduce Transparency the
    cards go solid.
  - Oswald (SIL Open Font License, `Shared/Fonts/Oswald-OFL.txt`) is bundled in the app and the
    widget extension. The app logs at launch whether every face registered, and the smoke test
    fails if one didn't.

## Widgets

One widget, **Next train**, in four sizes: small and medium on the Home Screen, rectangular and
inline on the Lock Screen. It shows the next train for the current direction (by clock, like the
app), its true departure time with a live countdown, its track and any delay or cancellation; medium
adds the next three trains. Its timeline carries an entry for each upcoming departure and for the
2 PM switch, and asks for a fresh one every 5 to 10 minutes (iOS decides how often it actually
reloads). The inline Lock Screen line keeps to the time plus one thing: the track, the delay
("+6m") or "Cancelled". Tapping it opens the app. The destination and look come from the app
through the App Group `group.com.lasmith1689.GlassRail`.

## Live Activity

Pinning a train also starts a Live Activity: the true pickup and drop-off times with each leg's
lateness, how far away each one is ("in 4 minutes", then "3 minutes ago"), the track, a journey bar
from your stop to your destination, and when the data was last updated with the train's position
as of then. There is no push server, so the app can only change the activity while it runs, and it
is built around that:

- **While Glass Rail is open**, the activity is live and follows the board (true times, track,
  position). It ends when you tap "Pinned · show next" or pin another train.
- **When you leave the app or lock the phone**, the activity is ended with its latest times and a
  dismissal time of 3 minutes after arrival. iOS removes it then, even if the app never runs again.
  Nothing on it reads the clock: the relative times and the journey bar are drawn by iOS from the
  ride's dates, so it moves from pickup to drop-off on its own. Delays that change after you left
  the app are not shown ("Updated 2:31 PM" says how old the times are).
- **When you come back** during the ride, a fresh live activity replaces the ended one.
- A ride that is over is ended right away, even when the board has switched direction at 2 PM or
  midnight in the meantime.

An ended Live Activity is not shown in the Dynamic Island, so the Dynamic Island shows the ride only
while the activity is live (its countdown switches from pickup to drop-off at the pickup time on
its own). Keeping it there after you leave the app would need a push server; ending it is what
guarantees it cannot linger on the Lock Screen after the ride.

## Where the data comes from

The phone talks to NJ Transit's public GraphQL endpoint directly
(`https://www.njtransit.com/api/graphql/graphql`, no API key), with exactly the queries and the one
header v4 sent: `getTripPlannerSchedule` (four lookups spread over the next few hours per direction),
`getTrainDepartureScreens` (tracks and status per origin station) and `getTrainStopList` (live stop
times, up to eight trains per refresh). There is no server. The widget reuses the app's data when
the direction it shows is at most 5 minutes old there; otherwise it fetches only the two directions
for your chosen terminal, with two planner lookups each (now and 75 minutes out).

If NJ Transit can't be reached, the board keeps the last live data (turning `STALE`); with nothing to
show at all it falls back to the bundled sample, labeled `SAMPLE`. A direction's planner counts as
failed when all of its lookups fail, or the first one (which covers the next trains). Only the
direction on screen has to refresh: when its planner fails (or, on a day with no trains at Watchung
Avenue, Bay Street's), the whole refresh counts as failed, so an outage never shows up as "No trains"
under a `LIVE` badge; that message only appears when NJ Transit answered with no trains. Any other
direction that fails keeps its trips from the last refresh, dated by when they were fetched, so it
turns `STALE` on its own clock: switch to it and the header says how old its trains are ("Updated 2m
ago", `STALE` after 3.5 minutes), and the app refreshes right away. The widget ("Updated 1:58 PM" on
the medium size) and the Live Activity ("Updated") show that same per-direction time, never the time
of a refresh that didn't reach them. A direction with nothing to carry over reads "Trains this way
didn't load" (the widget: "Not loaded"), never "No trains".

NJ Transit's planner does not answer "no trains" with an empty list. Asked about Watchung Avenue on a
Saturday, it replies HTTP 200 with a GraphQL error, "We're sorry. We were unable to find trips
between your origin and destination.", and a null schedule (the same reply for all four
directions). The app reads exactly that reply as "no trains", so the board says "No trains from
Watchung Ave" and lists the next trains from Bay Street. Any other GraphQL error, that text on an
HTTP error, a non-JSON reply or a missing schedule is still a failed lookup; so is a station name
the planner doesn't know, which gets a different error ("Cannot destructure property 'latLong'..."),
so a renamed station would show up as a failed refresh, never as "no trains". At 3 AM on a weekday
there is no gap to handle: the planner returns the first trains of the morning (4:48 AM toward the
city). These replies were captured from the live feed and are kept as test fixtures.

## Project layout

| Path | What |
|---|---|
| `Packages/GlassRailKit` | The port of v4's `lib/` plus the board engine shared by app and widget. Pure Swift, unit tested. |
| `Packages/GlassRailKit/Tests` | 249 tests: v4's 138 vitest cases, one XCTest each, plus 111 more for the NJ Transit parser and client (including replies captured from the live feed: a normal weekday, a Saturday with no trains at Watchung Avenue, and 3 AM), planner outages, directions carried over from an earlier refresh, the board engine, the Live Activity's timing rules, widget timelines and storage. |
| `GlassRail/` | The SwiftUI app. |
| `GlassRailWidgets/` | The WidgetKit extension. |
| `Shared/` | Theme, type scale and widget layouts, compiled into both targets. |
| `project.yml` | XcodeGen spec. CI generates `GlassRail.xcodeproj`; it is not committed. |
| `Config/` | Build settings, Info.plists, entitlements. |
| `tools/make-icon.py` | Redraws v4's icon at 1024x1024 without alpha. |

## Building

GitHub Actions is the only build machine. Every push runs CI (`.github/workflows/ci.yml`):

1. `swift test` for GlassRailKit on macOS, twice (the second time with the machine in India's time
   zone, to prove times never depend on the phone's zone).
2. A Simulator build of the app and widget, then a smoke test that launches it with live data and
   with each QA scenario, screenshots each screen and reads the text back. Every screen must show
   "Glass Rail" and its scenario's own text (`DELAYED`, `TRACK CHANGED`, `STALE`, `SAMPLE` with no
   delay or on-time claim, and so on), with a few more looks for a slow runner, or the job fails.
   The live launch must read `LIVE` or `STALE`, never `SAMPLE` (which would mean no refresh ever
   succeeded). In the riding scenario the Live Activity must start; leaving the app must end it with
   a dismissal time, logged only after ActivityKit's end call returned and with the activity then
   in its ended state; and coming back must end that copy and start a live one. Every theme draws
   the same words, so OCR can't tell Midnight from Glass: the Midnight screen is checked by colour
   instead (the backdrop beside the cards must be near-black, and clearly darker and less blue than
   the default theme's in the same scenario).
3. An App Store archive dry run that checks both bundles carry the App Group, then stops with
   "Nothing was uploaded".
4. An informational live probe of NJ Transit's feed from the runner. It also asks the planner about
   next Saturday at 10 AM and a weekday at 3 AM, publishes every raw reply to the `ci-njt-probe`
   branch, and fails its step unless Saturday reads as "No trains" with Bay Street instead and 3 AM
   lists the first morning trains. The job never blocks the rest of CI.

Shipping to TestFlight is separate and deliberate: see [TESTFLIGHT.md](TESTFLIGHT.md).

On a Mac with Xcode 26: `brew install xcodegen && xcodegen generate`, then open
`GlassRail.xcodeproj`, and set `DEVELOPMENT_TEAM = U3CTV4FLKM` in `Config/Shared.xcconfig` to run on a
device.

## QA scenarios

The live feed can't be forced into a delay or a track change, so, like v4's `?demo=`, the app accepts
launch arguments (used by CI's smoke test):

| Argument | Shows |
|---|---|
| `-GlassRailDemo delayed` | A train 6 minutes late at pickup, 2 at drop-off |
| `-GlassRailDemo track` | A track change after 4 seconds |
| `-GlassRailDemo departed` | The hero departs after 12 seconds |
| `-GlassRailDemo stale` | Old live data |
| `-GlassRailDemo sample` | Sample data (no alerts) |
| `-GlassRailDemo riding` | A pinned train mid-ride, which then drops off the feed |
| `-GlassRailSheet later\|stops\|settings` | Opens that sheet |
| `-GlassRailWidgetGallery YES` | The widget layouts and the Live Activity's Lock Screen layout, rendered in the app |
| `-GlassRailTheme midnight` | A theme, without saving it |

## Differences from v4

- No server. v4's `/api/trains` and `/api/stops` ran on Vercel; the phone now makes those calls.
  When NJ Transit fails, v4's server replaced the board with sample data; the app keeps the last live
  data and marks it `STALE` instead, and uses the sample only when it has nothing else.
- v4 ignored failed planner lookups, so a planner outage read as "No trains from Watchung Ave". The
  app treats it as a failed refresh for the direction on screen and keeps the last trips, with their
  own time, for the others (see above).
- A manual AM/PM flip lapses at the next 2 PM or midnight boundary. v4's rule, ported unchanged,
  would honour a morning flip to PM again the next morning; v4 never hit this because a reload
  dropped the flip, but an iOS app can stay in memory for days.
- v4 joined board notes with an em dash; the port uses a middle dot (same length, so duplicate
  itineraries still rank the same).
- The Liquid theme keeps v4's palette and highlight but not the tilt-to-move effect; the controls use
  iOS 26 Liquid Glass instead.
- v4's Glass theme laid a milky full-screen card over everything, so nothing showed through. The
  app's Glass theme drops it: dark midnight backdrop, light text, and see-through glass cards.
- The widget follows the clock and ignores pins and manual flips.
- With nothing left to show this way on sample or stale data, the hero says "No more trains this
  way" rather than v4's "No trains from Watchung Ave", which is reserved for live data.
- Sample data never shows a train as late or on time. v4.2's true-time path applied live stop
  times even in `SAMPLE` mode; the app uses stop-list timing only with live data.
