#!/bin/bash
set -eu

[ "$(id -u)" != 0 ] || { echo "Run as yourself, not with sudo: ./uninstall.sh"; exit 1; }
ID=com.mshannon.sidetone
INSTALLED="/Applications/Sidetone.app"
case "${1:-}" in
  "") mode=uninstall ;;
  --delete-settings) mode=everything ;;
  --permissions-only) mode=permissions ;;
  *) echo "Usage: ./uninstall.sh [--delete-settings | --permissions-only]" >&2; exit 2 ;;
esac

pkill -x Sidetone || true
for _ in $(seq 1 10); do
  pgrep -x Sidetone >/dev/null || break
  sleep 0.5
done

# tccutil finds the app by its bundle identifier, so this runs before the app is removed.
tccutil reset Microphone "$ID" >/dev/null
echo "Reset Sidetone's microphone access."
if [ "$mode" = permissions ]; then
  open "$INSTALLED"
  echo "Opened Sidetone, so it asks for the microphone when you next start monitoring."
  exit 0
fi

rm -rf "$INSTALLED"
if [ "$mode" = everything ]; then
  defaults delete "$ID" 2>/dev/null || true
  echo "Uninstalled Sidetone and deleted its settings and presets."
else
  echo "Uninstalled Sidetone. Its settings and presets stay."
fi
