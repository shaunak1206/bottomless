#!/bin/zsh
# Runs the app core's integration tests against a local Worker (wrangler dev) with originals in R2 or in a local
# S3 imitation (moto), the same code path Google Cloud uses.
#   scripts/test_core.sh            # both modes
#   scripts/test_core.sh r2|s3      # one mode
set -euo pipefail
ROOT=${0:A:h:h}
MOTO=${MOTO_SERVER:-$HOME/freeraid/.venv/bin/moto_server}
if (( $# )); then MODES=($1); else MODES=(r2 s3); fi
export CI=1 WRANGLER_SEND_METRICS=false

run_mode() {
  local mode=$1 port=$2 motoport=$3
  local persist=$(mktemp -d -t bottomless-core)
  local token="core-test-$RANDOM$RANDOM"
  local pids=()
  if [[ $mode == s3 ]]; then
    "$MOTO" -H 127.0.0.1 -p $motoport >/dev/null 2>&1 & pids+=($!)
    for i in {1..50}; do curl -s -o /dev/null http://127.0.0.1:$motoport && break; sleep 0.2; done
    curl -s -X PUT http://127.0.0.1:$motoport/test-originals >/dev/null
  fi
  (cd $ROOT/backend && npx wrangler d1 migrations apply bottomless-catalog --local --persist-to $persist >/dev/null)
  (cd $ROOT/backend && exec npx wrangler dev --local --ip 127.0.0.1 --port $port --persist-to $persist \
      --show-interactive-dev-session=false --var APP_TOKEN:$token --var ORIGINALS_MODE:$mode \
      --var ORIG_ENDPOINT:http://127.0.0.1:$motoport --var ORIG_BUCKET:test-originals --var ORIG_REGION:us-east-1 \
      --var ORIG_ACCESS_KEY_ID:test --var ORIG_SECRET_ACCESS_KEY:test >$persist/wrangler.log 2>&1) & pids+=($!)
  for i in {1..150}; do curl -s -o /dev/null http://127.0.0.1:$port/v1/health && break; sleep 0.3; done
  echo "== core integration tests, originals in $mode"
  local rc=0
  (cd $ROOT/ios/Packages/BottomlessCore && BOTTOMLESS_TEST_API=http://127.0.0.1:$port BOTTOMLESS_TEST_TOKEN=$token \
      swift test --filter IntegrationTests 2>&1 | grep -E "Test Case.*(passed|failed)|error:|Executed|failed \(" ) || rc=1
  for p in $pids; do pkill -P $p 2>/dev/null || true; kill $p 2>/dev/null || true; done
  pkill -f "wrangler dev --local --ip 127.0.0.1 --port $port" 2>/dev/null || true
  rm -rf $persist
  return $rc
}

rc_all=0
for m in $MODES; do
  case $m in
    r2) run_mode r2 8796 0 || rc_all=1 ;;
    s3) run_mode s3 8795 5056 || rc_all=1 ;;
  esac
done
exit $rc_all
