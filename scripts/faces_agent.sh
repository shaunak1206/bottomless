#!/bin/zsh
# Runs scripts/faces.py on this Mac every 30 minutes (and at login), so photos backed up from the phone get their
# faces found and grouped into People without doing anything. Each run only looks at photos it has not seen.
#   scripts/faces_agent.sh install     # start now and keep running
#   scripts/faces_agent.sh uninstall
#   scripts/faces_agent.sh status
set -euo pipefail
ROOT=${0:A:h:h}
LABEL=com.shaunak.bottomless-faces
PLIST=~/Library/LaunchAgents/$LABEL.plist
PY=${FACES_PYTHON:-/opt/anaconda3/bin/python3}

case ${1:-status} in
  install)
    mkdir -p $ROOT/.faces ~/Library/LaunchAgents
    cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>-I</string><string>$ROOT/scripts/faces.py</string><string>run</string></array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>1800</integer>
  <key>StandardOutPath</key><string>$ROOT/.faces/agent.log</string>
  <key>StandardErrorPath</key><string>$ROOT/.faces/agent.log</string>
</dict></plist>
EOF
    launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
    launchctl bootstrap gui/$(id -u) $PLIST
    echo "installed: runs now, then every 30 minutes (log: .faces/agent.log)" ;;
  uninstall)
    launchctl bootout gui/$(id -u)/$LABEL 2>/dev/null || true
    rm -f $PLIST
    echo "removed" ;;
  status)
    launchctl print gui/$(id -u)/$LABEL 2>/dev/null | grep -E "state =|last exit code|runs =" || echo "not installed"
    $PY -I $ROOT/scripts/faces.py status ;;
esac
