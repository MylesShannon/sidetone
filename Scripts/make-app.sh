#!/bin/bash
# Assemble Sidetone.app from a SwiftPM build product.
#
# Usage: Scripts/make-app.sh [debug|release]
#
# Signing identity, in order of preference:
#   1. $SIDETONE_SIGN_IDENTITY
#   2. the "Sidetone Local" identity from Scripts/make-cert.sh
#   3. ad-hoc, whose designated requirement is a hash of this exact build, so
#      permissions granted to one build do not carry to the next
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
APP="$ROOT/.dist/Sidetone.app"

# Release builds are universal so Intel Macs are not quietly excluded. Development
# builds stay native, because building twice doubles the wait for no benefit.
#
# SwiftPM's own --arch arm64 --arch x86_64 needs Xcode's build system, which a
# Command Line Tools install does not have, so each slice is built separately and
# joined with lipo.
build_slice() {
	local arch="$1" scratch="$2"
	swift build -c "$CONFIG" --arch "$arch" --scratch-path "$scratch" --product Sidetone >&2
	swift build -c "$CONFIG" --arch "$arch" --scratch-path "$scratch" --show-bin-path
}

if [[ -n "${SIDETONE_UNIVERSAL:-}" ]]; then
	ARM_DIR="$(build_slice arm64 .build-arm64)"
	INTEL_DIR="$(build_slice x86_64 .build-x86_64)"
	BIN_DIR="$ARM_DIR"
else
	swift build -c "$CONFIG" --product Sidetone
	BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ -n "${SIDETONE_UNIVERSAL:-}" ]]; then
	lipo -create -output "$APP/Contents/MacOS/Sidetone" \
		"$ARM_DIR/Sidetone" "$INTEL_DIR/Sidetone"
else
	cp "$BIN_DIR/Sidetone" "$APP/Contents/MacOS/Sidetone"
fi

# Sparkle is a framework, so it has to travel inside the bundle. SwiftPM links it
# as @rpath, and the binary's own rpaths do not include Contents/Frameworks.
mkdir -p "$APP/Contents/Frameworks"
cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Sidetone" 2>/dev/null

sed -e "s/__VERSION__/$VERSION/g" Resources/Info.plist >"$APP/Contents/Info.plist"

if [[ -f "$ROOT/.dist/AppIcon.icns" ]]; then
	cp "$ROOT/.dist/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
	echo "note: no AppIcon.icns yet, run 'make icon'"
fi

if [[ -z "${SIDETONE_SIGN_IDENTITY:-}" ]]; then
	if security find-identity -v -p codesigning 2>/dev/null | grep -q "Sidetone Local"; then
		SIDETONE_SIGN_IDENTITY="Sidetone Local"
	else
		SIDETONE_SIGN_IDENTITY="-"
	fi
fi

# CI imports the identity into a throwaway keychain, which codesign does not search
# unless it is told to. Locally the identity is in the login keychain and this is
# not needed.
sign() {
	if [[ -n "${SIDETONE_KEYCHAIN:-}" ]]; then
		codesign --keychain "$SIDETONE_KEYCHAIN" "$@"
	else
		codesign "$@"
	fi
}

SIGN_ARGS=(--force --identifier com.mshannon.sidetone --entitlements Resources/Sidetone.entitlements)

# The hardened runtime turns on library validation, which requires embedded
# frameworks to share the process's Team ID. A self-signed certificate has no Team
# ID, so Sparkle then fails to load with "different Team IDs" and the app does not
# start at all. Only a Developer ID has a team, and only notarization needs the
# hardened runtime, so it is enabled for that case alone.
HARDENED=false
if [[ "$SIDETONE_SIGN_IDENTITY" == Developer\ ID* ]]; then
	HARDENED=true
	SIGN_ARGS+=(--options runtime)
fi

# Nested code is signed from the inside out. Sparkle ships an updater app and two
# XPC services, and the outer signature is only valid once those are settled.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
NESTED_ARGS=(--force)
if [[ "$HARDENED" == true ]]; then
	NESTED_ARGS+=(--options runtime --timestamp)
fi
for nested in \
	"$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
	"$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
	"$FRAMEWORK/Versions/B/Updater.app" \
	"$FRAMEWORK/Versions/B/Autoupdate" \
	"$FRAMEWORK/Versions/B" \
	"$FRAMEWORK"; do
	[[ -e "$nested" ]] || continue
	sign "${NESTED_ARGS[@]}" --sign "$SIDETONE_SIGN_IDENTITY" "$nested"
done

sign "${SIGN_ARGS[@]}" --sign "$SIDETONE_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2

# A hardened runtime without a Team ID cannot load its own embedded frameworks, so
# refuse to ship a bundle in that state.
DETAIL="$(codesign -dv "$APP" 2>&1)"
if grep -q 'flags=.*runtime' <<<"$DETAIL" && grep -q 'TeamIdentifier=not set' <<<"$DETAIL"; then
	echo "error: hardened runtime without a Team ID; embedded frameworks will not load" >&2
	exit 1
fi

echo "built $APP (version $VERSION, signed by '$SIDETONE_SIGN_IDENTITY')"
