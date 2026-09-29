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
  minutes or two failed refreshes; `SAMPLE` for the bundled fallback, which never shows delays or
  track changes.
- **No service**: when your station has no trains (the Montclair Branch runs none north of Bay Street
  on weekends), it says so and lists the next trains from Bay Street.
- Refreshes every 60 seconds, on returning to the app, with pull to refresh, and with the Refresh
  button. Five looks from v4 (Glass, Midnight, Aurora, Sunset, Liquid) in Settings.

## Widgets

One widget, **Next train**, in four sizes: small and medium on the Home Screen, rectangular and
inline on the Lock Screen. It shows the next train for the current direction (by clock, like the
app), its true departure time with a live countdown, its track and any delay or cancellation; medium
adds the next three trains. Its timeline carries an entry for each upcoming departure and for the
2 PM switch, and asks for a fresh one every 5 to 10 minutes (iOS decides how often it actually
reloads). Tapping it opens the app. The destination and look come from the app through the App Group
`group.com.lasmith1689.GlassRail`.

## Where the data comes from

The phone talks to NJ Transit's public GraphQL endpoint directly
(`https://www.njtransit.com/api/graphql/graphql`, no API key), with exactly the queries and the one
header v4 sent: `getTripPlannerSchedule` (four lookups spread over the next few hours per direction),
`getTrainDepartureScreens` (tracks and status per origin station) and `getTrainStopList` (live stop
times, up to eight trains per refresh). There is no server. The widget fetches only the two
directions for your chosen terminal, and reuses the app's data when the app refreshed in the last two
minutes.

If NJ Transit can't be reached, the board keeps the last live data (turning `STALE`); with nothing to
show at all it falls back to the bundled sample, labeled `SAMPLE`.

## Project layout

| Path | What |
|---|---|
| `Packages/GlassRailKit` | The port of v4's `lib/` plus the board engine shared by app and widget. Pure Swift, unit tested. |
| `Packages/GlassRailKit/Tests` | v4's 138 test cases, one XCTest per vitest case, plus tests for the NJ Transit parser (including real captured replies), the board engine and widget timelines. |
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
   with each QA scenario, checks it keeps running, screenshots each screen and reads the text back.
3. An App Store archive dry run that checks both bundles carry the App Group, then stops with
   "Nothing was uploaded".
4. An informational live probe of NJ Transit's feed from the runner.

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
| `-GlassRailWidgetGallery YES` | The widget layouts, rendered in the app |
| `-GlassRailTheme midnight` | A theme, without saving it |

## Differences from v4

- No server. v4's `/api/trains` and `/api/stops` ran on Vercel; the phone now makes those calls.
  When NJ Transit fails, v4's server replaced the board with sample data; the app keeps the last live
  data and marks it `STALE` instead, and uses the sample only when it has nothing else.
- A manual AM/PM flip lapses at the next 2 PM or midnight boundary. v4's rule, ported unchanged,
  would honour a morning flip to PM again the next morning; v4 never hit this because a reload
  dropped the flip, but an iOS app can stay in memory for days.
- v4 joined board notes with an em dash; the port uses a middle dot (same length, so duplicate
  itineraries still rank the same).
- The Liquid theme keeps v4's palette and highlight but not the tilt-to-move effect; the controls use
  iOS 26 Liquid Glass instead.
- The widget follows the clock and ignores pins and manual flips.
