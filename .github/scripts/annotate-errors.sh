#!/bin/bash
# Turns compiler and test errors in a build log into GitHub annotations, so failures are readable
# from the run summary without downloading logs.
#   annotate-errors.sh <log> [title]
# Emits up to 40 de-duplicated `::error file=<repo path>,line=<n>::<message>` lines (plain
# `::error::` when a line has no file), then the last 60 lines of the log.
set -uo pipefail
LOG="$1"
TITLE="${2:-Build}"
ROOT="${GITHUB_WORKSPACE:-$(pwd)}"
[ -f "$LOG" ] || { echo "::error::$TITLE log $LOG is missing"; exit 0; }

escape() { local s="$1"; s="${s//'%'/%25}"; s="${s//$'\r'/%0D}"; s="${s//$'\n'/%0A}"; printf '%s' "$s"; }

count=0
while IFS= read -r line; do
  [ "$count" -ge 40 ] && break
  if [[ "$line" =~ ^(/[^:]+):([0-9]+):([0-9]+:)?\ error:\ (.*)$ ]]; then
    file="${BASH_REMATCH[1]}"
    rel="${file#"$ROOT"/}"
    echo "::error file=$rel,line=${BASH_REMATCH[2]},title=$TITLE::$(escape "${BASH_REMATCH[4]}")"
  else
    echo "::error title=$TITLE::$(escape "$line")"
  fi
  count=$((count + 1))
done < <(grep -E "error:|\*\* (BUILD|ARCHIVE|TEST) FAILED|Fatal error" "$LOG" | grep -v "^warning:" | awk '!seen[$0]++')

echo "::group::Last 60 lines of $LOG"
tail -n 60 "$LOG"
echo "::endgroup::"
