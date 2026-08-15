#!/bin/bash
# Build .dist/AppIcon.icns from Resources/AppIcon.png (expects a 1024x1024 source).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SRC="Resources/AppIcon.png"
SET=".dist/AppIcon.iconset"

if [[ ! -f "$SRC" ]]; then
	echo "error: $SRC not found" >&2
	exit 1
fi

rm -rf "$SET"
mkdir -p "$SET"

for size in 16 32 64 128 256 512; do
	sips -z "$size" "$size" "$SRC" --out "$SET/icon_${size}x${size}.png" >/dev/null
	sips -z "$((size * 2))" "$((size * 2))" "$SRC" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 1024 1024 "$SRC" --out "$SET/icon_512x512@2x.png" >/dev/null
rm -f "$SET/icon_64x64.png" "$SET/icon_64x64@2x.png"

iconutil -c icns "$SET" -o .dist/AppIcon.icns
rm -rf "$SET"
echo "built .dist/AppIcon.icns"
