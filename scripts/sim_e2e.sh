#!/bin/zsh
# End-to-end in the iOS simulator: local backend, fresh app install, sample camera roll, UI tests, screenshots.
#   scripts/sim_e2e.sh [simulator-udid]
set -euo pipefail
ROOT=${0:A:h:h}
UDID=${1:-$(xcrun simctl list devices available | grep -m1 -E "iPhone" | grep -oE '[0-9A-F-]{36}')}
DATA=${E2E_DATA:-$ROOT/.secrets/e2e-backend}
PORT=8794
SHOTS=$ROOT/docs/screenshots
MEDIA=$DATA/media
BUNDLE=com.shaunakkapur.bottomless

if ! curl -s -m 2 http://127.0.0.1:$PORT/v1/health >/dev/null; then
  $ROOT/scripts/local_backend.sh $PORT $DATA > $DATA.log 2>&1 &
  for i in {1..90}; do curl -s -m 2 http://127.0.0.1:$PORT/v1/health >/dev/null && break; sleep 1; done
fi
TOKEN=$(cat $DATA/token)
api() { curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:$PORT$1; }

echo "== simulator $UDID"
xcrun simctl boot $UDID 2>/dev/null || true
xcrun simctl bootstatus $UDID -b >/dev/null

echo "== build"
cd $ROOT/ios
xcodegen generate >/dev/null
xcodebuild -project Bottomless.xcodeproj -scheme Bottomless -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/sim build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | sort -u

echo "== fresh install + sample camera roll"
xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true
xcrun simctl uninstall $UDID $BUNDLE 2>/dev/null || true
xcrun simctl install $UDID build/sim/Build/Products/Debug-iphonesimulator/Bottomless.app
xcrun simctl privacy $UDID grant photos $BUNDLE
[[ -d $MEDIA ]] || swift $ROOT/scripts/make_media.swift $MEDIA 30 2 >/dev/null
xcrun simctl addmedia $UDID $MEDIA/*.jpg $MEDIA/*.mov
before=$(api /v1/stats | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).ready))')
SIMCTL_CHILD_BOTTOMLESS_API_BASE=http://127.0.0.1:$PORT SIMCTL_CHILD_BOTTOMLESS_TOKEN=$TOKEN xcrun simctl launch $UDID $BUNDLE >/dev/null
for i in {1..60}; do
  sleep 3
  s=$(api /v1/stats)
  pending=$(echo $s | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).pending))')
  ready=$(echo $s | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).ready))')
  (( i > 5 && pending == 0 )) && break
done
echo "   cloud items before: $before, after: $ready (pending $pending)"
LIVE_ID=$(node $ROOT/scripts/seed_live.mjs http://127.0.0.1:$PORT $DATA/token $(ls $MEDIA/*.jpg | head -1) $(ls $MEDIA/*.mov | head -1))
echo "   cloud-only Live Photo $LIVE_ID"
xcrun simctl terminate $UDID $BUNDLE 2>/dev/null || true

echo "== UI tests"
mkdir -p $SHOTS
TEST_RUNNER_BOTTOMLESS_API_BASE=http://127.0.0.1:$PORT TEST_RUNNER_BOTTOMLESS_TOKEN=$TOKEN TEST_RUNNER_SCREENSHOT_DIR=$SHOTS \
  TEST_RUNNER_LIVE_ID=$LIVE_ID \
  xcodebuild test -project Bottomless.xcodeproj -scheme Bottomless -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath build/sim 2>&1 | grep -E "Test Case.*(passed|failed)|error:|\*\* TEST"
