#!/bin/bash
set -eu

[ "$(id -u)" != 0 ] || { echo "Run as yourself, not with sudo: ./build.sh"; exit 1; }
[ $# = 0 ] || { echo "Usage: ./build.sh"; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

ID=com.mshannon.sidetone
VERSION=$(cat VERSION)
STAGE="$HERE/build/Sidetone.app"
FRAMEWORK="$STAGE/Contents/Frameworks/Sparkle.framework"

# SIDETONE_SIGN names a command that signs a release build; it's called with a path, its identifier, and for code that
# needs them, --entitlements and a file. Without it, builds are signed ad hoc, and without the hardened runtime, whose
# library validation would refuse Sparkle for having a different Team ID than an ad hoc app's none.
if [ -n "${SIDETONE_SIGN:-}" ]; then
  sign() { $SIDETONE_SIGN "$@"; }
else
  sign() {
    local target=$1 identifier=$2
    shift 2
    codesign --force --sign - --identifier "$identifier" "$@" "$target"
  }
fi

# SwiftPM's own --arch arm64 --arch x86_64 needs Xcode's build system, so each slice is built on its own and joined with lipo.
slice() {
  if ! swift build -c release --arch "$1" --scratch-path ".build-$1" --product Sidetone \
    -Xswiftc -file-prefix-map -Xswiftc "$HERE=." > "build/swift-$1.log" 2>&1; then
    tail -n 30 "build/swift-$1.log" >&2
    echo "Building Sidetone for $1 failed." >&2
    exit 1
  fi
  swift build -c release --arch "$1" --scratch-path ".build-$1" --show-bin-path
}

echo "Building Sidetone $VERSION for Apple silicon and Intel..."
mkdir -p build
ARM=$(slice arm64)
INTEL=$(slice x86_64)

rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" "$STAGE/Contents/Frameworks"
lipo -create -output "$STAGE/Contents/MacOS/Sidetone" "$ARM/Sidetone" "$INTEL/Sidetone"
# Without this, the binary keeps the paths of the folder it was built in.
strip -S -x "$STAGE/Contents/MacOS/Sidetone"
# SwiftPM links Sparkle as @rpath, and the binary's own rpaths don't include Contents/Frameworks.
cp -R "$ARM/Sparkle.framework" "$STAGE/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$STAGE/Contents/MacOS/Sidetone" 2>/dev/null
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$STAGE/Contents/Info.plist"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$STAGE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Inside out, because the outer signature is only valid once the code inside it is settled. Sparkle's parts keep the
# identifiers and entitlements Sparkle gave them.
for nested in XPCServices/Downloader.xpc XPCServices/Installer.xpc Updater.app Autoupdate ""; do
  path="$FRAMEWORK/Versions/B/$nested"
  [ -e "$path" ] || continue
  identifier=$(codesign -dv "$path" 2>&1 | sed -n 's/^Identifier=//p')
  entitlements="build/$(basename "$path").entitlements"
  codesign -d --entitlements - --xml "$path" > "$entitlements" 2>/dev/null || true
  if [ -s "$entitlements" ]; then
    sign "$path" "$identifier" --entitlements "$entitlements"
  else
    sign "$path" "$identifier"
  fi
  rm -f "$entitlements"
done
sign "$STAGE" "$ID" --entitlements Resources/Sidetone.entitlements
codesign --verify --deep --strict "$STAGE"

if [ -n "${SIDETONE_SIGN:-}" ]; then
  echo "Built build/Sidetone.app."
else
  echo "Built build/Sidetone.app, signed ad hoc, so macOS asks for the microphone again after each rebuild."
fi
