#!/bin/zsh
# Runs the Worker locally (wrangler dev) with its own D1/R2 data, for the simulator and manual testing.
#   scripts/local_backend.sh [port] [data-dir]
# Prints the token it uses to <data-dir>/token. Originals go to a local R2 bucket.
set -euo pipefail
ROOT=${0:A:h:h}
PORT=${1:-8794}
DATA=${2:-$ROOT/.secrets/local-backend}
mkdir -p $DATA
[[ -f $DATA/token ]] || openssl rand -hex 24 > $DATA/token
chmod 600 $DATA/token
export CI=1 WRANGLER_SEND_METRICS=false
cd $ROOT/backend
npx wrangler d1 migrations apply bottomless-catalog --local --persist-to $DATA >/dev/null
echo "local backend on http://127.0.0.1:$PORT (token in $DATA/token)"
exec npx wrangler dev --local --ip 0.0.0.0 --port $PORT --persist-to $DATA --show-interactive-dev-session=false \
  --var APP_TOKEN:$(cat $DATA/token) --var ORIGINALS_MODE:r2
