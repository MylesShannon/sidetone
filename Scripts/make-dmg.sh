#!/bin/bash
# Build a DMG that is signed locally but not notarized.
#
# Notarization needs a paid Apple Developer membership. Without it macOS refuses
# to open the app on any machine that downloaded it, until the user allows it in
# System Settings. Use Scripts/make-release.sh instead once a Developer ID is
# available.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(cat VERSION)"
APP=".dist/Sidetone.app"
STAGE=".dist/dmg"
DMG=".dist/Sidetone-$VERSION.dmg"

Scripts/make-icon.sh
SIDETONE_UNIVERSAL=1 Scripts/make-app.sh release

echo "==> staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/Sidetone.app"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Sidetone $VERSION" -srcfolder "$STAGE" \
	-ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# Sparkle will not install an update it cannot verify, so the appcast has to be
# regenerated and signed with the private key in the login keychain every time a
# DMG changes. generate_appcast reads every DMG in the folder it is given.
# A universal build uses its own scratch directories, so Sparkle's tools are not
# always under .build. Missing them used to be a warning, which quietly shipped a
# DMG the appcast did not describe: an update that can never install.
find_generate_appcast() {
	local scratch
	for scratch in .build .build-arm64 .build-x86_64; do
		local candidate="$scratch/artifacts/sparkle/Sparkle/bin/generate_appcast"
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

if [[ -n "${SIDETONE_SKIP_APPCAST:-}" ]]; then
	# CI has no signing key, and an unsigned appcast is worse than none.
	echo "note: skipping the appcast, this DMG is not a release"
else
	if ! GENERATE_APPCAST="$(find_generate_appcast)"; then
		echo "error: generate_appcast not found under .build, .build-arm64 or .build-x86_64" >&2
		echo "       run 'swift package resolve' first" >&2
		exit 1
	fi

	echo "==> signing the appcast"
	RELEASES=".dist/releases"
	mkdir -p "$RELEASES"
	cp "$DMG" "$RELEASES/"

	# generate_appcast picks up release notes from an HTML file named after the
	# archive, which is what Sparkle shows in its update dialog. Without it people
	# are asked to install a version number and nothing else.
	NOTES="docs/release-notes/$VERSION.html"
	if [[ -f "$NOTES" ]]; then
		cp "$NOTES" "$RELEASES/Sidetone-$VERSION.html"
	else
		echo "note: no $NOTES, the update dialog will have nothing to show"
	fi

	# Locally the key comes from the keychain. CI has no keychain worth trusting, so
	# it passes the key in a file instead. Spelled out twice rather than built as an
	# array, because bash 3.2 treats an empty array as an unbound variable.
	PREFIX="https://github.com/MylesShannon/sidetone/releases/download/v$VERSION/"
	if [[ -n "${SIDETONE_ED_KEY_FILE:-}" ]]; then
		"$GENERATE_APPCAST" --ed-key-file "$SIDETONE_ED_KEY_FILE" \
			--download-url-prefix "$PREFIX" -o docs/appcast.xml "$RELEASES"
	else
		"$GENERATE_APPCAST" --download-url-prefix "$PREFIX" -o docs/appcast.xml "$RELEASES"
	fi
	echo "wrote docs/appcast.xml"
fi

cat <<EOF

built $DMG

This DMG is not notarized. Anyone who downloads it will be stopped the first time
they open the app, and will have to allow it in System Settings under Privacy &
Security. Building from source with 'make install' avoids that entirely, because
macOS only quarantines files that were downloaded.
EOF
