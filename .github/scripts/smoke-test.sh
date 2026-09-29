#!/bin/bash
# Installs the Simulator build, launches it (live data first, then each QA scenario), captures
# screenshots and fails if the app is not running when it should be.
#   smoke-test.sh <simulator-udid> <path/to/GlassRail.app> [output-dir]
set -uo pipefail
UDID="$1"
APP="$2"
OUT="${3:-screenshots}"
mkdir -p "$OUT"
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

shoot() {
  for attempt in 1 2 3; do
    run_limited 30 xcrun simctl io "$UDID" screenshot --type=png "$OUT/$1.png" >/dev/null 2>&1
    [ "$(stat -f%z "$OUT/$1.png" 2>/dev/null || echo 0)" -gt 60000 ] && break
    echo "... $1 still loading (attempt $attempt)"
    sleep 4
  done
}

# capture <file> <seconds to wait> [launch arguments...]
capture() {
  local name="$1" wait="$2"
  shift 2
  run_limited 30 xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1 || true
  run_limited 60 xcrun simctl launch "$UDID" "$BUNDLE" "$@" >/dev/null
  sleep "$wait"
  if alive; then
    shoot "$name"
    mark "$name"
  else
    echo "::error title=Smoke test::Glass Rail is not running after ${wait}s ($name $*)"
    failures=$((failures + 1))
  fi
}

# 1. Live NJ Transit data from the runner. Must still be running after 15+ seconds.
capture 01-live 20
sleep 5
if alive; then echo "Glass Rail still running 25 s after a live launch"; else
  echo "::error title=Smoke test::Glass Rail stopped running after the live launch"; failures=$((failures + 1)); fi

# 2. v4's QA scenarios.
capture 02-delayed 6 -GlassRailDemo delayed
capture 03-track-changed 8 -GlassRailDemo track
capture 04-riding 9 -GlassRailDemo riding
capture 04b-riding-before-drop 3 -GlassRailDemo riding
capture 05-departed 13 -GlassRailDemo departed
capture 06-stale 5 -GlassRailDemo stale
capture 07-sample 5 -GlassRailDemo sample
capture 08-later-sheet 6 -GlassRailDemo delayed -GlassRailSheet later
capture 09-stops-sheet 6 -GlassRailDemo riding -GlassRailSheet stops
capture 10-settings 5 -GlassRailSheet settings
capture 11-widgets 6 -GlassRailDemo delayed -GlassRailWidgetGallery YES
capture 12-theme-midnight 5 -GlassRailDemo delayed -GlassRailTheme midnight

echo "::notice title=Smoke test timeline::${timeline[*]}"

if [ "$failures" -gt 0 ]; then
  find ~/Library/Logs/DiagnosticReports -name "GlassRail*" -mmin -20 -print -exec head -120 {} \; 2>/dev/null
  exit 1
fi
echo "Glass Rail launched every scenario without crashing"

echo "::group::App log (errors and faults)"
xcrun simctl spawn "$UDID" log show --last 5m --style compact \
  --predicate "process == \"GlassRail\" AND (messageType == error OR messageType == fault)" 2>/dev/null | tail -n 60 || true
echo "::endgroup::"
