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
launched=""
riding_pid=""

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

# The OCR and pixel readers, compiled once (running them as scripts costs ~10 s per call).
TOOLS="$(mktemp -d)"
OCR="$TOOLS/ocr"
PIXELS="$TOOLS/pixels"
for tool in ocr pixels; do
  if ! xcrun swiftc -O -o "$TOOLS/$tool" "$SCRIPT_DIR/$tool.swift" 2>tool-build.log; then
    cat tool-build.log
    echo "::error title=Smoke test::Could not build the $tool reader, so screens can't be checked"
    exit 1
  fi
done
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
  launched=$(run_limited 60 xcrun simctl launch "$UDID" "$BUNDLE" "$@" 2>&1)
  sleep "$wait"
  if ! alive; then
    # A slow runner can leave a launch unfinished (simctl itself timing out): launch once more,
    # and say so, before calling it a failure. A crash at launch fails again.
    echo "::notice title=Smoke test::$name: not running ${wait}s after launch (simctl: $(printf '%s' "$launched" | tr '\n' ' ' | cut -c1-200)); launching once more"
    launched=$(run_limited 60 xcrun simctl launch "$UDID" "$BUNDLE" "$@" 2>&1)
    sleep "$wait"
  fi
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
# coming back must replace it with a live one. The app logs each end only after ActivityKit's
# end call has returned, with the activity's resulting state, so these checks see what the
# system did, not what the app meant to do.
lifecycle_check() {
  local log after
  log=$(activity_log 3m)
  echo "::group::Live Activity log after the riding launch"
  echo "$log"
  echo "::endgroup::"
  if [[ "$log" != *"Live Activity started"* ]]; then
    echo "::error title=Live Activity::Pinning a ride did not start a Live Activity (log above: $(printf '%s' "$log" | tail -3 | tr '\n' '/'))."
    failures=$((failures + 1))
    return
  fi
  run_limited 60 xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null 2>&1
  sleep 6
  # For the record: what the Dynamic Island shows once the app is in the background.
  run_limited 30 xcrun simctl io "$UDID" screenshot --type=png "$OUT/04c-backgrounded.png" >/dev/null 2>&1
  run_limited 60 "$OCR" "$OUT/04c-backgrounded.png" > "$OUT/ocr/04c-backgrounded.txt" 2>/dev/null
  cat "$OUT/ocr/04c-backgrounded.txt" >> "$OCR_TXT"
  # On a busy runner Settings can take longer than that to come up, and ActivityKit longer to end
  # the activity: keep looking for the line for up to 40 seconds before calling it missing.
  local ended="" waited=0
  while :; do
    log=$(activity_log 2m)
    ended=$(printf '%s\n' "$log" | grep "ended on suspend" | tail -1)
    [ -n "$ended" ] && break
    [ "$waited" -ge 40 ] && break
    sleep 5
    waited=$((waited + 5))
  done
  [ "$waited" -gt 0 ] && echo "::notice title=Live Activity::The end on suspend was logged ${waited}s after the first look."
  if [ -n "$ended" ] && [[ "$ended" == *"dismissal at"* ]] && [[ "$ended" == *"state ended"* ]]; then
    echo "::notice title=Live Activity::Backgrounded: ${ended#*Live Activity }"
  else
    echo "::error title=Live Activity::Going to the background did not end the activity with a dismissal date (expected 'ended on suspend ... dismissal at ... state ended' after the end call returned). Log: $(printf '%s' "$log" | tail -5 | tr '\n' '/')"
    failures=$((failures + 1))
    return
  fi
  # Back to the app the way a tap on its icon does it. (`simctl openurl` would ask "Open in Glass
  # Rail?" from Settings and leave that alert over every later screen.)
  local back
  back=$(run_limited 60 xcrun simctl launch "$UDID" "$BUNDLE" 2>&1)
  # Long enough for a couple of the board's 10-second ticks after the replacement.
  sleep 25
  log=$(activity_log 2m)
  after=$(printf '%s\n' "$log" | awk '/ended on suspend/ { seen = 1; next } seen')
  echo "::group::Live Activity log after returning to the app"
  echo "$after"
  echo "::endgroup::"
  local how="same process, pid ${back##*: }"
  [ "${back##*: }" = "$riding_pid" ] || how="relaunched: pid $riding_pid then ${back##*: }"
  local since
  since=$(printf '%s\n' "$after" | sed -E 's/^.*(Live Activit)/\1/' | tr '\n' '/' | cut -c1-900)
  if [[ "$after" != *"Live Activity started"* ]]; then
    echo "::error title=Live Activity::Returning to the app ($how) did not start a live activity again. Log since: $since"
    failures=$((failures + 1))
  elif ! printf '%s\n' "$after" | grep -Eq '\(replaced by a live activity\), state (ended|dismissed)'; then
    # The ended copy stays listed until it is dismissed, so it must be ended for good to make way.
    echo "::error title=Live Activity::Back in the foreground ($how) the ended activity was not removed in favour of the live one (no 'replaced by a live activity' after the end call returned). Log since: $since"
    failures=$((failures + 1))
  else
    echo "::notice title=Live Activity::Back in the foreground ($how): a live activity replaced the ended one. Log since: $since"
  fi
}

# Every theme draws the same text, so OCR can't tell them apart. This reads colour instead: the
# backdrop in the left gutter beside the cards. Midnight's is near-black (tokens 0A0C14 to 02030A
# with faint glows); the default Glass backdrop there is deep blue under bright glows. The same
# scenario in the default theme (02-delayed) is measured alongside, so the check proves the theme
# argument changed the look rather than just that the screen is dark.
# The Station theme draws its text in bundled Oswald faces. A wrong file or PostScript name falls
# back to the system font without an error, so the app logs what registered at launch.
font_check() {
  local log
  log=$(run_limited 120 xcrun simctl spawn "$UDID" log show --last 5m --style compact \
    --predicate 'subsystem == "com.lasmith1689.GlassRail" AND category == "Fonts"' 2>/dev/null | grep "Theme fonts" | tail -1)
  if [[ "$log" == *"Theme fonts: all"* ]]; then
    echo "::notice title=Fonts::${log#*Theme fonts}"
  else
    echo "::error title=Fonts::The app did not report every theme face loaded. Log: ${log:-(nothing)}"
    failures=$((failures + 1))
  fi
}

# Every new theme must actually draw its own backdrop, not Glass's: compare the left gutter beside
# the cards, in two bands (upper and lower, where the themes' glows sit), with the same scenario in
# the default theme. The drifting lights move a little between runs, so the bar is generous.
distinct_check() {
  local name upper lower g_upper g_lower d1 d2 d
  g_upper=$(run_limited 30 "$PIXELS" "$OUT/02-delayed.png" 0 0.25 0.025 0.45)
  g_lower=$(run_limited 30 "$PIXELS" "$OUT/02-delayed.png" 0 0.72 0.025 0.95)
  for name in 12b-theme-platform 12c-theme-ember 12d-theme-navy 12e-theme-station; do
    upper=$(run_limited 30 "$PIXELS" "$OUT/$name.png" 0 0.25 0.025 0.45)
    lower=$(run_limited 30 "$PIXELS" "$OUT/$name.png" 0 0.72 0.025 0.95)
    d1=$(rgb_distance "$upper" "$g_upper")
    d2=$(rgb_distance "$lower" "$g_lower")
    if [ -z "$d1" ] || [ -z "$d2" ]; then
      echo "::error title=Smoke test: $name::Could not read the backdrop colour ('$upper' '$lower')"
      failures=$((failures + 1))
      continue
    fi
    d=$(( d1 > d2 ? d1 : d2 ))
    if [ "$d" -lt 60 ]; then
      echo "::error title=Smoke test: $name::The backdrop looks like Glass's (colour distance $d, needs 60): upper rgb($upper), lower rgb($lower)."
      failures=$((failures + 1))
    else
      echo "::notice title=Theme $name::Backdrop differs from Glass by $d (upper rgb($upper), lower rgb($lower))."
    fi
  done
}

# rgb_distance "r g b" "r g b": sum of absolute channel differences, empty if either is unreadable.
rgb_distance() {
  local r1 g1 b1 r2 g2 b2
  read -r r1 g1 b1 <<< "$1"
  read -r r2 g2 b2 <<< "$2"
  [ -n "${b1:-}" ] && [ -n "${b2:-}" ] || return 0
  echo $(( (r1 > r2 ? r1 - r2 : r2 - r1) + (g1 > g2 ? g1 - g2 : g2 - g1) + (b1 > b2 ? b1 - b2 : b2 - b1) ))
}

theme_check() {
  local midnight glass mr mg mb gr gg gb
  midnight=$(run_limited 30 "$PIXELS" "$OUT/12-theme-midnight.png" 0 0.2 0.025 0.8)
  glass=$(run_limited 30 "$PIXELS" "$OUT/02-delayed.png" 0 0.2 0.025 0.8)
  read -r mr mg mb <<< "$midnight"
  read -r gr gg gb <<< "$glass"
  if [ -z "${mb:-}" ] || [ -z "${gb:-}" ]; then
    echo "::error title=Smoke test: 12-theme-midnight::Could not read the backdrop colour (Midnight '$midnight', Glass '$glass')"
    failures=$((failures + 1))
  elif [ "$mb" -le 65 ] && [ $((mb * 10)) -le $((gb * 7)) ]; then
    echo "::notice title=Theme::Midnight backdrop rgb($mr, $mg, $mb) against Glass rgb($gr, $gg, $gb) in the same scenario."
  else
    echo "::error title=Smoke test: 12-theme-midnight::The Midnight theme did not draw its near-black backdrop: rgb($mr, $mg, $mb), Glass in the same scenario rgb($gr, $gg, $gb) (needs blue at most 65 and at most 70% of Glass)."
    failures=$((failures + 1))
  fi
}

# 1. Live NJ Transit data from the runner. SAMPLE means the app never got a live answer (or
#    counted every refresh as failed), so it fails this screen. Must still be running after 15+ s.
capture 01-live 20 '(^|[^a-z])(LIVE|STALE)([^a-z]|$) && YOUR RIDE && !(^|[^a-z])SAMPLE([^a-z]|$)'
sleep 5
if alive; then echo "Glass Rail still running 25 s after a live launch"; else
  echo "::error title=Smoke test::Glass Rail stopped running after the live launch"; failures=$((failures + 1)); fi

# 2. v4's QA scenarios, each with the text that proves it rendered.
capture 02-delayed 6 'DELAYED && Originally' -GlassRailDemo delayed
capture 03-track-changed 8 'TRACK CHANGED' -GlassRailDemo track
capture 04-riding 9 'PINNED && Arrives in' -GlassRailDemo riding
riding_pid="${launched##*: }"
lifecycle_check
mark "live activity lifecycle"
capture 04b-riding-before-drop 3 'Arrives in' -GlassRailDemo riding
capture 05-departed 13 'Train 1078' -GlassRailDemo departed
capture 06-stale 5 'STALE && outdated' -GlassRailDemo stale
# Sample data never shows a delay, and never claims a train is on time.
capture 07-sample 5 'SAMPLE && SCHEDULED && !DELAYED && !ON TIME' -GlassRailDemo sample
capture 08-later-sheet 6 'Arrives [0-9]' -GlassRailDemo delayed -GlassRailSheet later
capture 09-stops-sheet 6 'ALL STOPS' -GlassRailDemo riding -GlassRailSheet stops
capture 10-settings 5 'Home station && Watchung Avenue && Choose a look' -GlassRailSheet settings
# Any NJ Transit rail station can be home, Watchung Avenue first as the default.
capture 10c-home-station 5 'Home station && Watchung Avenue && Absecon && Allendale' -GlassRailSheet home
# NJ Transit's travel alerts: a red link in the header that takes no room, so "Later this way"
# stays on screen; and the sheet it opens, with the alerts in full.
capture 10a-alerts 6 'SERVICE ALERTS && LATER THIS WAY && DELAYED' -GlassRailDemo delayed -GlassRailAlerts YES
capture 10b-alerts-sheet 6 'Midtown && honored && Portal' -GlassRailDemo delayed -GlassRailAlerts YES -GlassRailSheet alerts
capture 11-widgets 6 'LATER THIS WAY && LIVE ACTIVITY && DROP-OFF' -GlassRailDemo delayed -GlassRailWidgetGallery YES
capture 12-theme-midnight 5 'DELAYED' -GlassRailDemo delayed -GlassRailTheme midnight
theme_check
# The four looks from the September design samples, and the widget gallery in the one with its
# own typeface (Oswald), which the widget extension bundles too.
capture 12b-theme-platform 5 'DELAYED' -GlassRailDemo delayed -GlassRailTheme platform
capture 12c-theme-ember 5 'DELAYED' -GlassRailDemo delayed -GlassRailTheme ember
capture 12d-theme-navy 5 'DELAYED' -GlassRailDemo delayed -GlassRailTheme navy
capture 12e-theme-station 5 'DELAYED' -GlassRailDemo delayed -GlassRailTheme station
capture 12f-station-widgets 6 'LATER THIS WAY' -GlassRailDemo delayed -GlassRailTheme station -GlassRailWidgetGallery YES
capture 12g-platform-widgets 6 'LATER THIS WAY' -GlassRailDemo delayed -GlassRailTheme platform -GlassRailWidgetGallery YES
capture 12h-ember-widgets 6 'LATER THIS WAY' -GlassRailDemo delayed -GlassRailTheme ember -GlassRailWidgetGallery YES
capture 12i-navy-widgets 6 'LATER THIS WAY' -GlassRailDemo delayed -GlassRailTheme navy -GlassRailWidgetGallery YES
font_check
distinct_check
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
