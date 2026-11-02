#!/bin/zsh
# Imports a Google Photos export (Google Takeout zips) into Bottomless with Google's dates, places and favorites.
#   scripts/import_google_photos.sh <account> ~/Downloads/takeout-*.zip
# <account> names the progress file (.import/<account>.sqlite). Use one per Google account, since two accounts can both
# have "Photos from 2019/IMG_0001.jpg". Each zip is deleted once its extraction is verified, and the extracted copy
# once it imported cleanly. Re-running is safe; parts can arrive in any order.
set -euo pipefail
ROOT=${0:A:h:h}
(( $# >= 2 )) || { echo "usage: $0 <account> takeout-....zip [more zips or extracted folders]" >&2; exit 2; }
ACCOUNT=$1; shift
BIN=$ROOT/ios/Packages/BottomlessCore/.build/release/bottomless-import
[[ -x $BIN ]] || (cd $ROOT/ios/Packages/BottomlessCore && swift build -c release --product bottomless-import >/dev/null)
mkdir -p $ROOT/.import
exec $BIN --api "$(cat $ROOT/.secrets/api_url)" --token-file $ROOT/.secrets/app_token \
  --state $ROOT/.import/$ACCOUNT.sqlite --delete-zips "$@"
