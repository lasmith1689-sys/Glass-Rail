#!/bin/bash
# Prints "<name>|<udid>" for an available iPhone simulator (prefers iPhone 17 Pro on the newest runtime).
set -euo pipefail
list=$(xcrun simctl list devices available)
line=$(echo "$list" | grep -E "^ +iPhone 17 Pro \(" | tail -1 || true)
[ -z "$line" ] && line=$(echo "$list" | grep -E "^ +iPhone 17 \(" | tail -1 || true)
[ -z "$line" ] && line=$(echo "$list" | grep -E "^ +iPhone" | tail -1)
name=$(echo "$line" | sed -E 's/^ +//; s/ \([0-9A-F-]{36}\).*//')
udid=$(echo "$line" | grep -oE '[0-9A-F-]{36}')
echo "$name|$udid"
