#!/bin/zsh
# Keeps the free-Apple-ID build of Bottomless from expiring (free signing lasts 7 days). Safe to run as often as you
# like: it does nothing until the app's provisioning profile has under 3 days left, then needs the iPhone reachable
# (plugged in, or on the same Wi-Fi after it has been paired with this Mac once) and reinstalls a freshly signed build.
# The app keeps its data across the reinstall.
set -uo pipefail
ROOT=${0:A:h:h}
PROFILES=~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
BUNDLE=com.shaunakkapur.bottomless
log() { print -r -- "$(date '+%F %T') $*"; }

expires=0
for p in $PROFILES/*.mobileprovision(N); do
  plist=$(security cms -D -i "$p" 2>/dev/null) || continue
  [[ $plist == *".$BUNDLE<"* ]] || continue
  e=$(print -r -- "$plist" | plutil -extract ExpirationDate raw -o - - 2>/dev/null) || continue
  t=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$e" +%s 2>/dev/null) || continue
  (( t > expires )) && expires=$t
done
left=$(( (expires - $(date +%s)) / 3600 ))
if (( expires > 0 && left > 72 )); then log "signature good for ${left}h more; nothing to do"; exit 0; fi

log "signature has ${left}h left; re-signing"
# A new 7-day profile is only issued once the old one is gone.
for p in $PROFILES/*.mobileprovision(N); do
  security cms -D -i "$p" 2>/dev/null | grep -q ".$BUNDLE<" && rm -f "$p"
done
if $ROOT/scripts/install_phone.sh; then log "re-signed and reinstalled"; else log "iPhone not reachable; will try again next run"; exit 1; fi
