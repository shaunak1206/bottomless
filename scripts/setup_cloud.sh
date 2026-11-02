#!/bin/zsh
# Creates (or reuses) everything in the cloud and deploys the Worker. Safe to re-run.
#   scripts/setup_cloud.sh r2     # originals in Cloudflare R2 (free up to 10 GB total)
#   scripts/setup_cloud.sh gcs    # originals in Google Cloud Storage, Archive class (needs gcloud login + billing)
# Secrets are generated here and piped straight into `wrangler secret put`; they are kept in .secrets/ (mode 600)
# and in ios/Config/Secrets.xcconfig for the app build, and never printed.
set -euo pipefail
ROOT=${0:A:h:h}
MODE=${1:-r2}
SECRETS=$ROOT/.secrets
mkdir -p $SECRETS && chmod 700 $SECRETS
export CI=1 WRANGLER_SEND_METRICS=false
W=(npx wrangler)
cd $ROOT/backend

say() { print -P "%F{cyan}==>%f $*"; }

say "Cloudflare account"
$W whoami 2>&1 | grep -q "You are logged in" || { echo "run: npx wrangler login"; exit 1; }

say "D1 database"
DBID=$($W d1 list --json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s).find(d=>d.name==="bottomless-catalog");process.stdout.write(r?r.uuid:"")})')
if [[ -z $DBID ]]; then
  $W d1 create bottomless-catalog >/dev/null
  DBID=$($W d1 list --json | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{process.stdout.write(JSON.parse(s).find(d=>d.name==="bottomless-catalog").uuid)})')
fi
sed -i '' -E "s/\"database_id\": \"[0-9a-f-]+\"/\"database_id\": \"$DBID\"/" wrangler.jsonc
$W d1 migrations apply bottomless-catalog --remote >/dev/null
echo "   bottomless-catalog $DBID (migrations applied)"

say "R2 buckets"
existing=$($W r2 bucket list 2>/dev/null | awk "/^name:/{print \$2}" || true)
for b in bottomless-derived bottomless-originals; do
  if ! print -l -- $existing | grep -qx -- $b; then $W r2 bucket create $b >/dev/null; echo "   created $b"; else echo "   $b exists"; fi
done

say "App token"
[[ -s $SECRETS/app_token ]] || openssl rand -hex 32 > $SECRETS/app_token
chmod 600 $SECRETS/app_token

# Spending guardrails (see backend/src/caps.ts). Override per run: CAP_NEW_ASSETS_MONTH=5000 scripts/setup_cloud.sh gcs
CAPS=(--var CAP_NEW_ASSETS_MONTH:${CAP_NEW_ASSETS_MONTH:-40000} --var CAP_DOWNLOAD_GB_MONTH:${CAP_DOWNLOAD_GB_MONTH:-5} --var CAP_STORED_GB:${CAP_STORED_GB:-300})
VARS=(--var ORIGINALS_MODE:$MODE --var TRASH_DAYS:30)
if [[ $MODE == gcs ]]; then
  VARS=(--var ORIGINALS_MODE:s3 --var TRASH_DAYS:30)
  say "Google Cloud Storage (Archive)"
  PROJECT=$(gcloud config get-value project 2>/dev/null)
  [[ -n $PROJECT ]] || { echo "run: gcloud config set project <id>"; exit 1; }
  [[ $(gcloud billing projects describe $PROJECT --format='value(billingEnabled)') == True ]] || { echo "billing is not enabled on $PROJECT"; exit 1; }
  gcloud services enable storage.googleapis.com iam.googleapis.com --project $PROJECT >/dev/null
  BUCKET=$(cat $SECRETS/gcs_bucket 2>/dev/null || echo "bottomless-originals-$(openssl rand -hex 4)")
  if ! gcloud storage buckets describe gs://$BUCKET --project $PROJECT >/dev/null 2>&1; then
    gcloud storage buckets create gs://$BUCKET --project $PROJECT --location us-central1 --default-storage-class ARCHIVE \
      --uniform-bucket-level-access --public-access-prevention >/dev/null
    echo "   created gs://$BUCKET (us-central1, ARCHIVE)"
  fi
  echo $BUCKET > $SECRETS/gcs_bucket
  SA=bottomless-worker@$PROJECT.iam.gserviceaccount.com
  gcloud iam service-accounts describe $SA --project $PROJECT >/dev/null 2>&1 || \
    gcloud iam service-accounts create bottomless-worker --project $PROJECT --display-name "Bottomless Worker" >/dev/null
  gcloud storage buckets add-iam-policy-binding gs://$BUCKET --member serviceAccount:$SA --role roles/storage.objectAdmin >/dev/null
  if [[ ! -s $SECRETS/gcs_hmac.json ]]; then
    gcloud storage hmac create $SA --project $PROJECT --format=json > $SECRETS/gcs_hmac.json
    chmod 600 $SECRETS/gcs_hmac.json
    echo "   created an HMAC key for $SA"
  fi
  node -e 'const k=require(process.argv[1]);process.stdout.write(k.metadata?.accessId??k.accessId)' $SECRETS/gcs_hmac.json | $W secret put ORIG_ACCESS_KEY_ID >/dev/null
  node -e 'const k=require(process.argv[1]);process.stdout.write(k.secret)' $SECRETS/gcs_hmac.json | $W secret put ORIG_SECRET_ACCESS_KEY >/dev/null
  VARS+=(--var ORIG_ENDPOINT:https://storage.googleapis.com --var ORIG_BUCKET:$BUCKET --var ORIG_REGION:auto)
fi

say "Deploy"
$W deploy ${VARS[@]} ${CAPS[@]} > $SECRETS/deploy.log 2>&1 || { tail -20 $SECRETS/deploy.log; exit 1; }
URL=$(grep -oE 'https://bottomless-api\.[a-z0-9-]+\.workers\.dev' $SECRETS/deploy.log | head -1)
[[ -n $URL ]] || { echo "deployed, but no workers.dev URL found (is a workers.dev subdomain registered?)"; tail -20 $SECRETS/deploy.log; exit 1; }
$W secret put APP_TOKEN < $SECRETS/app_token >/dev/null
echo $URL > $SECRETS/api_url
echo "   $URL"

say "App build settings (ios/Config/Secrets.xcconfig)"
TEAM=$(grep -E '^BOTTOMLESS_TEAM_ID' $ROOT/ios/Config/Secrets.xcconfig 2>/dev/null | sed -E 's/.*= *//' || true)
umask 077
{
  echo "// written by scripts/setup_cloud.sh; not committed"
  echo "BOTTOMLESS_API_BASE = ${URL/https:\/\//https:/\$()/}"
  echo "BOTTOMLESS_TOKEN = $(cat $SECRETS/app_token)"
  echo "BOTTOMLESS_TEAM_ID = ${TEAM}"
} > $ROOT/ios/Config/Secrets.xcconfig

say "Live smoke test"
node $ROOT/scripts/smoke.mjs $URL $SECRETS/app_token
