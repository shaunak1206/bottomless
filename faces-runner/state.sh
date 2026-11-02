#!/bin/bash
# Moves the face index (.faces/index.sqlite) between this runner and the Worker's R2 bucket.
#   scripts/state.sh get    a missing index (first run) is fine; any other failure stops the job, so a run that could
#                           not read the index never overwrites it with an empty one
#   scripts/state.sh put
set -euo pipefail
F=.faces/index.sqlite
URL="$BOTTOMLESS_API_URL/v1/faces/state"
mkdir -p .faces
case "$1" in
  get)
    code=$(curl -sS -o "$F.part" -w '%{http_code}' -H "Authorization: Bearer $BOTTOMLESS_TOKEN" "$URL")
    if [ "$code" = 200 ]; then mv "$F.part" "$F"; echo "face index: $(du -h "$F" | cut -f1)"
    elif [ "$code" = 404 ]; then rm -f "$F.part" "$F"; echo "no face index yet; starting one"
    else echo "could not read the face index (HTTP $code)"; exit 1; fi ;;
  put)
    [ -s "$F" ] || { echo "nothing to save"; exit 0; }
    curl -fsS -X PUT -H "Authorization: Bearer $BOTTOMLESS_TOKEN" -H 'Content-Type: application/octet-stream' \
      --data-binary @"$F" "$URL"; echo ;;
esac
