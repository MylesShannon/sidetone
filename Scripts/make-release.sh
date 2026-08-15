#!/bin/bash
# Build a signed, notarized, stapled DMG.
#
# Required environment:
#   SIDETONE_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   SIDETONE_KEYCHAIN_PROFILE  notarytool profile name, created once with:
#       xcrun notarytool store-credentials SIDETONE_NOTARY \
#           --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Without those the script explains what is missing and stops. It never produces
# an artifact that claims to be notarized when it is not.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
APP=".dist/Sidetone.app"
STAGE=".dist/dmg"
DMG=".dist/Sidetone-$VERSION.dmg"

missing=()
[[ -n "${SIDETONE_SIGN_IDENTITY:-}" ]] || missing+=("SIDETONE_SIGN_IDENTITY (a Developer ID Application identity)")
[[ -n "${SIDETONE_KEYCHAIN_PROFILE:-}" ]] || missing+=("SIDETONE_KEYCHAIN_PROFILE (a notarytool stored credential)")

if ((${#missing[@]})); then
	echo "cannot produce a notarized release yet. Missing:"
	printf '  - %s\n' "${missing[@]}"
	echo
	echo "Both require a paid Apple Developer Program membership."
	echo "For an unnotarized build run 'make dmg', or 'make install' for local use."
	exit 1
fi

if [[ "$SIDETONE_SIGN_IDENTITY" != Developer\ ID\ Application* ]]; then
	echo "error: notarization requires a Developer ID Application identity," >&2
	echo "       got '$SIDETONE_SIGN_IDENTITY'" >&2
	exit 1
fi

Scripts/make-icon.sh
SIDETONE_UNIVERSAL=1 Scripts/make-app.sh release

echo "==> re-signing with hardened runtime and secure timestamp (needs network)"
codesign --force --timestamp --options runtime \
	--identifier com.mshannon.sidetone \
	--entitlements Resources/Sidetone.entitlements \
	--sign "$SIDETONE_SIGN_IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "==> staging DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Sidetone.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sidetone $VERSION" -srcfolder "$STAGE" \
	-ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$SIDETONE_SIGN_IDENTITY" "$DMG"

echo "==> notarizing (needs network, can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$SIDETONE_KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "==> verifying"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# Sparkle will not install what it cannot verify, and the DMG just changed, so the
# appcast has to be re-signed here too rather than only in make-dmg.sh.
GENERATE_APPCAST=".build/artifacts/sparkle/Sparkle/bin/generate_appcast"
if [[ -x "$GENERATE_APPCAST" ]]; then
	echo "==> signing the appcast"
	RELEASES=".dist/releases"
	mkdir -p "$RELEASES"
	cp "$DMG" "$RELEASES/"
	"$GENERATE_APPCAST" \
		--download-url-prefix "https://github.com/MylesShannon/sidetone/releases/download/v$VERSION/" \
		-o docs/appcast.xml \
		"$RELEASES"
	echo "wrote docs/appcast.xml"
else
	echo "warning: $GENERATE_APPCAST is missing, so the appcast was NOT updated" >&2
fi

rm -rf "$STAGE"
echo "released $DMG"
