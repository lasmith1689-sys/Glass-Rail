#!/bin/bash
# Installs the Simulator build, launches it (live data first, then each QA scenario), screenshots
# each screen and reads it back with OCR. A screen passes only when its text contains "Glass Rail"
# and the scenario's own markers, so a blank, hung or wrong screen fails the job. Slow runners get
# a few more looks at the same launch before a screen counts as failed.
#   smoke-test.sh <simulator-udid> <path/to/GlassRail.app> [screenshot-dir] [ocr-output]
set -uo pipefail
UDID="$1"
APP="$2"
OUT="${3:-screenshots}"
OCR_TXT="${4:-ocr.txt}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT/ocr"
: > "$OCR_TXT"
BUNDLE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
failures=0

started=$SECONDS
timeline=()
mark() { timeline+=("$1 $((SECONDS - started))s"); echo "[$((SECONDS - started))s] $1"; }

# run_limited <seconds> <command...>: macOS has no `timeout`, so a stuck simctl call can't hang the job.
run_limited() {
  local limit="$1"
  shift
  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      kill -9 "$pid" 2>/dev/null
      echo "timed out after ${limit}s: $*"
      timeline+=("TIMEOUT($*)")
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

# The OCR reader, compiled once (running it as a script costs ~10 s per call).
OCR="$(mktemp -d)/ocr"
if ! xcrun swiftc -O -o "$OCR" "$SCRIPT_DIR/ocr.swift" 2>ocr-build.log; then
  cat ocr-build.log
  echo "::error title=Smoke test::Could not build the OCR reader, so screens can't be checked"
  exit 1
fi
mark "ocr built"

run_limited 120 xcrun simctl boot "$UDID" 2>/dev/null || true
run_limited 600 xcrun simctl bootstatus "$UDID" -b >/dev/null || true
mark booted
run_limited 30 xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true
run_limited 180 xcrun simctl install "$UDID" "$APP"
mark installed

alive() {
  # Read the whole list first: `| grep -q` exits early, launchctl dies of SIGPIPE, and with
  # pipefail that reads as "not running" even when the app is.
  local services
  services=$(run_limited 30 xcrun simctl spawn "$UDID" launchctl list 2>/dev/null)
  [[ "$services" == *"UIKitApplication:$BUNDLE"* ]]
}

# verify <ocr text> <spec>: "Glass Rail" plus every " && "-separated extended regex in <spec> must
# appear (case-insensitive); a term starting with "!" must not. Sets $problems.
verify() {
  local file="$1" rest="Glass Rail && $2" term
  problems=""
  while [ -n "$rest" ]; do
    term="${rest%% && *}"
    if [ "$term" = "$rest" ]; then rest=""; else rest="${rest#* && }"; fi
    if [ "${term:0:1}" = "!" ]; then
      if grep -Eiq -- "${term:1}" "$file"; then problems+="[shows '${term:1}'] "; fi
    else
      if ! grep -Eiq -- "$term" "$file"; then problems+="[no '$term'] "; fi
    fi
  done
  [ -z "$problems" ]
}

# capture <file> <seconds to wait> <expected text> [launch arguments...]
capture() {
  local name="$1" wait="$2" spec="$3"
  shift 3
  run_limited 30 xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  run_limited 60 xcrun simctl launch "$UDID" "$BUNDLE" "$@" >/dev/null
  sleep "$wait"
  local attempt passed=0 text="$OUT/ocr/$name.txt"
  for attempt in 1 2 3 4 5; do
    if ! alive; then
      echo "::error title=Smoke test::Glass Rail is not running ($name $*)"
      failures=$((failures + 1))
      return
    fi
    run_limited 30 xcrun simctl io "$UDID" screenshot --type=png "$OUT/$name.png" >/dev/null 2>&1
    run_limited 60 "$OCR" "$OUT/$name.png" > "$text" 2>/dev/null
    if verify "$text" "$spec"; then
      passed=1
      break
    fi
    echo "... $name, look $attempt: $problems"
    [ "$attempt" -lt 5 ] && sleep 6
  done
  cat "$text" >> "$OCR_TXT"
  if [ "$passed" = 1 ]; then
    mark "$name (look $attempt)"
  else
    local seen
    seen=$(sed -E 's/^ *[0-9]+%  //' "$text" | tr '\n' '/' | cut -c1-500)
    echo "::error title=Smoke test: $name::Expected content never appeared after 5 looks: $problems. Screen text: $seen"
    failures=$((failures + 1))
    mark "$name FAILED"
  fi
}

activity_log() {
  run_limited 120 xcrun simctl spawn "$UDID" log show --last "$1" --style compact \
    --predicate 'subsystem == "com.lasmith1689.GlassRail" AND category == "LiveActivity"' 2>/dev/null |
    grep "Live Activit" || true
}

# The riding scenario pins a ride, which starts a Live Activity. Going to the background must end
# it with a dismissal date (so it leaves the Lock Screen after the ride without the app), and
# coming back must replace it with a live one.
lifecycle_check() {
  local log after
  log=$(activity_log 3m)
  echo "::group::Live Activity log after the riding launch"
  echo "$log"
  echo "::endgroup::"
  if [[ "$log" != *"Live Activity started"* ]]; then
    echo "::warning title=Live Activity::The Simulator did not start a Live Activity (log above), so its lifecycle was not checked here."
    return
  fi
  run_limited 60 xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null 2>&1
  sleep 6
  log=$(activity_log 2m)
  local ended
  ended=$(printf '%s\n' "$log" | grep "ended on suspend" | tail -1)
  if [ -n "$ended" ] && [[ "$ended" == *"dismissal at"* ]]; then
    echo "::notice title=Live Activity::Backgrounded: ${ended#*Live Activity }"
  else
    echo "::error title=Live Activity::Going to the background did not end the activity with a dismissal date. Log: $(printf '%s' "$log" | tail -5 | tr '\n' '/')"
    failures=$((failures + 1))
    return
  fi
  run_limited 60 xcrun simctl openurl "$UDID" "glassrail://board" >/dev/null 2>&1
  sleep 8
  log=$(activity_log 2m)
  after=$(printf '%s\n' "$log" | awk '/ended on suspend/ { seen = 1; next } seen')
  echo "::group::Live Activity log after returning to the app"
  echo "$after"
  echo "::endgroup::"
  if [[ "$after" == *"Live Activity started"* ]]; then
    echo "::notice title=Live Activity::Back in the foreground: a live activity replaced the ended one."
  else
    echo "::error title=Live Activity::Returning to the app did not start a live activity again."
    failures=$((failures + 1))
  fi
}

# 1. Live NJ Transit data from the runner (or the labeled fallback if the feed can't be reached).
#    Must still be running after 15+ seconds.
capture 01-live 20 'LIVE|STALE|SAMPLE && YOUR RIDE'
sleep 5
if alive; then echo "Glass Rail still running 25 s after a live launch"; else
  echo "::error title=Smoke test::Glass Rail stopped running after the live launch"; failures=$((failures + 1)); fi

# 2. v4's QA scenarios, each with the text that proves it rendered.
capture 02-delayed 6 'DELAYED && Originally' -GlassRailDemo delayed
capture 03-track-changed 8 'TRACK CHANGED' -GlassRailDemo track
capture 04-riding 9 'PINNED && Arrives in' -GlassRailDemo riding
lifecycle_check
mark "live activity lifecycle"
capture 04b-riding-before-drop 3 'Arrives in' -GlassRailDemo riding
capture 05-departed 13 'Train 1078' -GlassRailDemo departed
capture 06-stale 5 'STALE && outdated' -GlassRailDemo stale
# Sample data never shows a delay, and never claims a train is on time.
capture 07-sample 5 'SAMPLE && SCHEDULED && !DELAYED && !ON TIME' -GlassRailDemo sample
capture 08-later-sheet 6 'Arrives [0-9]' -GlassRailDemo delayed -GlassRailSheet later
capture 09-stops-sheet 6 'ALL STOPS' -GlassRailDemo riding -GlassRailSheet stops
capture 10-settings 5 'Choose a look' -GlassRailSheet settings
capture 11-widgets 6 'LATER THIS WAY && LIVE ACTIVITY && DROP-OFF' -GlassRailDemo delayed -GlassRailWidgetGallery YES
capture 12-theme-midnight 5 'DELAYED' -GlassRailDemo delayed -GlassRailTheme midnight
# The Live Activity's Lock Screen layout mid-ride: the pickup is in the past, the drop-off ahead,
# both drawn by relative-time text the system keeps current.
capture 13-live-activity 8 'LIVE ACTIVITY && DROP-OFF && ago && in [0-9]+ min' -GlassRailDemo riding -GlassRailWidgetGallery YES

echo "::notice title=Smoke test timeline::${timeline[*]}"

if [ "$failures" -gt 0 ]; then
  find ~/Library/Logs/DiagnosticReports -name "GlassRail*" -mmin -30 -print -exec head -120 {} \; 2>/dev/null
  exit 1
fi
echo "Glass Rail showed the expected content on every screen"

echo "::group::App log (errors and faults)"
xcrun simctl spawn "$UDID" log show --last 5m --style compact \
  --predicate "process == \"GlassRail\" AND (messageType == error OR messageType == fault)" 2>/dev/null | tail -n 60 || true
echo "::endgroup::"
