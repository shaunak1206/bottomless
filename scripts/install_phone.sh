#!/bin/zsh
# Builds, signs (free Personal Team) and installs Bottomless on the connected iPhone, then launches it.
# Before: plug the phone in and tap Trust, turn on Developer Mode, sign into Xcode (Settings → Accounts).
#   scripts/install_phone.sh [team-id]
set -euo pipefail
ROOT=${0:A:h:h}
SECRETS_XC=$ROOT/ios/Config/Secrets.xcconfig
[[ -f $SECRETS_XC ]] || { echo "run scripts/setup_cloud.sh first"; exit 1; }

echo "== iPhone"
# devicectl's table shows a UDID or a CoreDevice id depending on the Xcode version, so read its JSON instead.
LIST=$(mktemp -t devices)
xcrun devicectl list devices --json-output $LIST >/dev/null 2>&1 || true
DEVICE_INFO=$(node -e '
  const all = (JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).result || {}).devices || [];
  const phones = all.filter(d => d.hardwareProperties?.reality === "physical" && d.hardwareProperties?.platform === "iOS");
  phones.sort((a, b) => (b.connectionProperties?.tunnelState === "connected") - (a.connectionProperties?.tunnelState === "connected"));
  const d = phones[0];
  if (d) console.log(d.hardwareProperties.udid, d.deviceProperties?.name ?? "iPhone");
' $LIST 2>/dev/null || true)
rm -f $LIST
DEVICE=${DEVICE_INFO%% *}
[[ -n $DEVICE ]] || { echo "no iPhone found: plug it in, unlock it, tap Trust"; exit 1; }
echo "   ${DEVICE_INFO#* } ($DEVICE)"

echo "== team"
TEAM=${1:-$(grep -E '^BOTTOMLESS_TEAM_ID *= *[A-Z0-9]{10}' $SECRETS_XC | sed -E 's/.*= *//' || true)}
if [[ -z $TEAM ]]; then
  # Personal Team id from the "Apple Development" signing certificate Xcode creates after you sign in.
  TEAM=$(security find-certificate -a -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
         | grep -oE 'OU *= *[A-Z0-9]{10}' | head -1 | grep -oE '[A-Z0-9]{10}' || true)
fi
[[ -n $TEAM ]] || { echo "no team: in Xcode open Settings → Accounts, sign in, then pick the team once in the project (Signing & Capabilities)"; exit 1; }
sed -i '' -E "s/^BOTTOMLESS_TEAM_ID *=.*/BOTTOMLESS_TEAM_ID = $TEAM/" $SECRETS_XC
grep -q '^BOTTOMLESS_TEAM_ID' $SECRETS_XC || echo "BOTTOMLESS_TEAM_ID = $TEAM" >> $SECRETS_XC
echo "   $TEAM"

echo "== build + sign"
cd $ROOT/ios
xcodegen generate >/dev/null
xcodebuild -project Bottomless.xcodeproj -scheme Bottomless -configuration Debug -destination "id=$DEVICE" \
  -derivedDataPath build/device -allowProvisioningUpdates -allowProvisioningDeviceRegistration build 2>&1 \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)|Signing|provision" | sort -u
APP=build/device/Build/Products/Debug-iphoneos/Bottomless.app

echo "== install"
xcrun devicectl device install app --device $DEVICE $APP
xcrun devicectl device process launch --device $DEVICE com.shaunakkapur.bottomless || \
  echo "installed. On the phone: Settings → General → VPN & Device Management → trust your Apple ID, then open Bottomless."
