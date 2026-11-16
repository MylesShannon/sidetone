#!/bin/bash
set -eu
trap 'echo "publish.sh stopped at line $LINENO. The output above says why." >&2' ERR
[ "$(id -u)" != 0 ] || { echo "Run as yourself, not with sudo: ./publish.sh <notes.md>" >&2; exit 1; }
[ $# = 1 ] || { echo "Usage: ./publish.sh <notes.md>" >&2; exit 2; }
[ -f "$1" ] || { echo "$1 isn't a file." >&2; exit 1; }
NOTES=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

REPO=MylesShannon/sidetone
NOTARY_PROFILE=${NOTARY_PROFILE:-notary}

[ -n "${SIDETONE_SIGN:-}" ] || { echo "Set SIDETONE_SIGN to the command that signs release builds. See docs/development.md." >&2; exit 1; }
# Over SSH, macOS leaves Homebrew's folders off PATH.
command -v gh >/dev/null || PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
command -v gh >/dev/null || { echo "The GitHub CLI isn't installed. Install it with: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login" >&2; exit 1; }
[ "$(git branch --show-current)" = main ] || { echo "Switch to main first." >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or remove your changes first. Keep the notes outside the repo or in build/." >&2; exit 1; }

VERSION=$(cat VERSION)
TAG="v$VERSION"
DMG="$HERE/build/Sidetone-$VERSION.dmg"
UPDATE_NOTES="docs/release-notes/$VERSION.html"
[ -f "$UPDATE_NOTES" ] || { echo "Write and commit $UPDATE_NOTES first. Sparkle's update dialog shows it." >&2; exit 1; }

git fetch --quiet origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "Push main first, so the release matches GitHub." >&2; exit 1; }
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null; then
  echo "$TAG is already on GitHub. Raise VERSION for a new release." >&2
  exit 1
fi

echo "Checking..."
mkdir -p build
if ! swift build -c debug --product Verify > build/verify.log 2>&1 || ! "$(swift build -c debug --show-bin-path)/Verify" >> build/verify.log 2>&1; then
  tail -n 30 build/verify.log >&2
  echo "The checks failed, so nothing was published." >&2
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

./build.sh

APP=build/Sidetone.app
if codesign -dv "$APP" 2>&1 | grep -q 'Signature=adhoc'; then
  echo "build/Sidetone.app is signed ad hoc, which Apple won't notarize. Check SIDETONE_SIGN." >&2
  exit 1
fi

echo "Notarizing Sidetone $VERSION with Apple..."
ditto -c -k --keepParent "$APP" "$work/notarize.zip"
out=$(xcrun notarytool submit "$work/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || {
  echo "Notarizing didn't finish. If notarytool has no saved login yet, add one with: xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
  exit 1
}
[ "$(jq -r .status <<<"$out")" = Accepted ] || {
  echo "Apple didn't accept Sidetone. See why with: xcrun notarytool log $(jq -r .id <<<"$out") --keychain-profile $NOTARY_PROFILE" >&2
  exit 1
}
xcrun stapler staple -q "$APP"
spctl --assess --type execute "$APP"

mkdir "$work/dmg" "$work/releases"
ditto build/Sidetone.app "$work/dmg/Sidetone.app"
ln -s /Applications "$work/dmg/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Sidetone $VERSION" -srcfolder "$work/dmg" -format UDZO "$DMG"

# Sparkle won't install an update it can't verify, so the appcast gets this DMG's size and EdDSA signature, made with
# the private key Sparkle's generate_keys put in your login Keychain. The HTML named after the DMG becomes the notes
# in the update dialog.
cp "$DMG" "$work/releases/"
cp "$UPDATE_NOTES" "$work/releases/Sidetone-$VERSION.html"
echo "Signing the appcast..."
SPARKLE=.build-arm64/artifacts/sparkle/Sparkle/bin
# The Sparkle key trusts /usr/bin/security, which Sparkle updates don't change, so SSH can read it without a dialog.
mkdir -p .build
if ! key=$(security find-generic-password -s https://sparkle-project.org -a sidetone -w 2> .build/sparkle-key.log); then
  cat .build/sparkle-key.log >&2
  echo "Reading the Sparkle key from your login Keychain failed, so nothing was published. Unlock the Keychain with: security unlock-keychain. If it was unlocked, allow /usr/bin/security once at the Mac's own Terminal, as docs/development.md says." >&2
  exit 1
fi
printf '%s' "$key" > "$work/sparkle-key"
unset key
"$SPARKLE/generate_appcast" --ed-key-file "$work/sparkle-key" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" -o docs/appcast.xml "$work/releases"
rm -f "$work/sparkle-key"
# The appcast lists every release, so the entry is found by file name.
declared=$(sed -n "s|.*$(basename "$DMG")\" length=\"\([0-9]*\)\".*|\1|p" docs/appcast.xml)
if [ "$declared" != "$(stat -f %z "$DMG")" ]; then
  git checkout -- docs/appcast.xml
  echo "The appcast doesn't describe $(basename "$DMG"), so nothing was published." >&2
  exit 1
fi

git add docs/appcast.xml
git commit --quiet -m "chore: appcast for $TAG"
git tag -a "$TAG" -m "Sidetone $VERSION"
if ! git push --quiet --atomic origin main "refs/tags/$TAG"; then
  echo "GitHub turned the push away, so main has the appcast commit and $TAG only here." >&2
  echo "Push them with: git push --atomic origin main refs/tags/$TAG, then run: gh release create $TAG build/$(basename "$DMG") --repo $REPO --title \"Sidetone $VERSION\" --notes-file <notes.md>" >&2
  exit 1
fi

echo "Creating the $TAG release..."
if ! gh release create "$TAG" "$DMG" --repo "$REPO" --title "Sidetone $VERSION" --notes-file "$NOTES" --verify-tag; then
  echo "$TAG is pushed but the release wasn't made. Make it from that tag on GitHub and upload build/$(basename "$DMG")." >&2
  exit 1
fi

echo "Published Sidetone $VERSION."
echo "It's at https://github.com/$REPO/releases/tag/$TAG."
echo "Pages serves the new appcast within a few minutes, and then Sparkle offers the update."
