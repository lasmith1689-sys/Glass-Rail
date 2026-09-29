#!/bin/bash
# Publishes screenshots as GitHub annotations so they can be reviewed from the run summary
# (GitHub allows 10 notices per step, so callers pass a range).
#   annotate-screens.sh text  <ocr.txt> <first> <last>   one notice per screen: its OCR text
#   annotate-screens.sh image <dir>     <first> <last>   one notice per screen: base64 JPEG
set -uo pipefail
MODE="$1"
SOURCE="$2"
FIRST="$3"
LAST="$4"

index=0
if [ "$MODE" = "text" ]; then
  [ -f "$SOURCE" ] || exit 0
  awk '/^===== /{ if (name) print name "\t" body; name=$2; body=""; next }
       { sub(/^ *[0-9]+%  /, ""); body = body (body ? " / " : "") $0 }
       END { if (name) print name "\t" body }' "$SOURCE" |
  while IFS=$'\t' read -r name body; do
    index=$((index + 1))
    if [ "$index" -ge "$FIRST" ] && [ "$index" -le "$LAST" ]; then
      echo "::notice title=OCR ${name}::${body:0:3000}"
    fi
  done
  exit 0
fi

for file in "$SOURCE"/*.png; do
  [ -f "$file" ] || continue
  index=$((index + 1))
  if [ "$index" -lt "$FIRST" ] || [ "$index" -gt "$LAST" ]; then continue; fi
  name=$(basename "$file" .png)
  for spec in "660 40" "560 34" "440 30"; do
    set -- $spec
    sips -Z "$1" -s format jpeg -s formatOptions "$2" "$file" --out "/tmp/$name.jpg" >/dev/null 2>&1
    data=$(base64 -i "/tmp/$name.jpg" | tr -d '\n')
    [ "${#data}" -lt 60000 ] && break
  done
  echo "::notice title=IMG ${name}::${data}"
done
