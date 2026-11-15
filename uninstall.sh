#!/bin/bash
set -eu
trap 'echo "uninstall.sh stopped at line $LINENO. The output above says why." >&2' ERR
[ "$(id -u)" != 0 ] || { echo "Run as yourself, not with sudo: ./uninstall.sh" >&2; exit 1; }
case "${1:-}" in
  "") mode=uninstall ;;
  --delete-settings) mode=everything ;;
  --permissions-only) mode=permissions ;;
  *) echo "Usage: ./uninstall.sh [--delete-settings | --permissions-only]" >&2; exit 2 ;;
esac
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

ID=com.mshannon.sidetone
INSTALLED="/Applications/Sidetone.app"

if [ "$mode" != permissions ] && [ -x "$INSTALLED/Contents/MacOS/Sidetone" ]; then
  "$INSTALLED/Contents/MacOS/Sidetone" unregister
fi
pkill -x Sidetone || true
for _ in $(seq 1 10); do
  pgrep -x Sidetone >/dev/null || break
  sleep 0.5
done

# tccutil finds the app by its bundle identifier, so this runs before the app is removed.
tccutil reset Microphone "$ID" >/dev/null
if [ "$mode" = permissions ]; then
  open "$INSTALLED"
  echo "Reset Sidetone's permissions and opened it, so it asks again."
  exit 0
fi

rm -rf "$INSTALLED"
if [ "$mode" = everything ]; then
  defaults delete "$ID" 2>/dev/null || true
  echo "Removed Sidetone and its settings and logs."
else
  echo "Removed Sidetone and kept its settings and logs."
fi
