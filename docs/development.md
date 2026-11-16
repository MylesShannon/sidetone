# Development

Needs a Swift 6 toolchain, from either Xcode or the Command Line Tools.

| Command                           | Result                                                      |
| --------------------------------- | ----------------------------------------------------------- |
| `./build.sh`                      | Build and sign `build/Sidetone.app` (git ignores `build/`)  |
| `./install.sh`                    | Build, put it in `/Applications` and open it                |
| `./install.sh path/Sidetone.app`  | Install a release's app after checking its signature        |
| `./uninstall.sh`                  | Remove it, its login item and its microphone access         |
| `./publish.sh notes.md`           | Check, build, notarize and publish a release                |

Run the scripts as yourself, not with sudo. `uninstall.sh` takes
`--delete-settings` to remove settings and presets too, or `--permissions-only` to
keep Sidetone installed, reset its microphone access and open it so it asks again.

## Signing

macOS keys microphone permission and the login item to an app's designated
requirement. An ad hoc signature pins that requirement to the hash of one exact
build, so every rebuild is a different app as far as those are concerned. A
certificate pins it to the bundle ID and that certificate, which survives updates.

`build.sh` signs ad hoc unless `SIDETONE_SIGN` names a command to sign with. It's
called with a path and its identifier, followed by `--entitlements <file>` for code
that has entitlements, and for a release it must make a Developer ID signature with
the hardened runtime and a secure timestamp, which notarization requires. For
example, a script that runs:

```bash
path=$1 identifier=$2
shift 2
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: <name> (<team>)" --identifier "$identifier" "$@" "$path"
```

`install.sh` resets microphone access whenever the signature changes, which for ad
hoc builds is every time.

`codesign -d -r- /Applications/Sidetone.app` shows what macOS checks. For a release
it's `identifier "com.mshannon.sidetone" and anchor apple generic and certificate
leaf = H"…"`.

Ad hoc builds leave the hardened runtime off. It turns on library validation, which
requires embedded frameworks to carry the same Team ID as the app, and an ad hoc
signature has none, so Sparkle would fail to load and the app wouldn't start.

Sparkle's updater app, XPC services and framework are signed from the inside out
before the app itself, each keeping the identifier and entitlements Sparkle gave it.

## Tests

`swift test` is not used. The Command Line Tools SDK ships neither XCTest nor
swift-testing, so a machine without a full Xcode install cannot run a normal test
target. The `Verify` executable covers the same ground with a small assertion
harness: ring buffer behaviour, resampling, drift control, gain and limiting,
metering, the FFT band mapping, latency profiles, settings migration, the feedback
rule, device resolution across a replug, hardware failure messages, and the
configuration change filter.

```sh
swift build --product Verify && "$(swift build --show-bin-path)/Verify"
```

`publish.sh` runs them before every release and stops if any fail.

If the toolchain refuses to build because Xcode is installed but its license was
never accepted, run `sudo xcodebuild -license accept`.

## Version numbers

The version comes from the `VERSION` file, and `build.sh` substitutes it into
`Resources/Info.plist` while assembling the bundle, so nothing is hardcoded in
Swift. `CFBundleVersion` gets the same string as `CFBundleShortVersionString`:
there is no separate build number, because nothing here needs one.

## Universal builds

`build.sh` builds for both architectures so Intel Macs are not excluded. SwiftPM's
`--arch arm64 --arch x86_64` needs Xcode's build system, which a Command Line Tools
install does not have, so each slice is built into its own scratch directory and
joined with `lipo`. Sparkle's framework is already universal, so it is copied
as-is.

## SDK

SwiftUI gates behaviour on the SDK an app was built against rather than the macOS
running it. Against newer SDKs a menu bar window that has been re-sized is
afterwards laid out at its ideal size, where anything flexible shrinks to its own
content. That is why the panel's controls take fixed widths from `Metrics` instead
of filling. Releases are built with whatever Xcode the release Mac has, so check
the panel after an Xcode update.

## Updates

Sparkle handles updates: it reads `docs/appcast.xml`, compares versions, shows its
own dialog, downloads, verifies, installs, and relaunches. `Resources/Info.plist`
carries `SUFeedURL` and `SUPublicEDKey`.

The private half of that key pair lives in the login keychain of the Mac that
publishes, put there by Sparkle's `generate_keys`. **Back it up.** Without it no
future release can be signed, and installs already in the wild have no way to
update.

`publish.sh` reads the key with `security find-generic-password` into its temporary
folder and passes it to `generate_appcast` with `--ed-key-file`, because over SSH
neither Sparkle tool can show the dialog that asks for the keychain. Once on each
Mac that publishes, at its own Terminal, run
`security find-generic-password -s https://sparkle-project.org -a ed25519 -w >/dev/null`,
enter the login password and click **Always Allow**, so `security` can read the key
without asking. Sparkle updates don't undo that.

Release notes for the update dialog live in `docs/release-notes/<version>.html`.
Without one, the update dialog offers a version number and nothing else. Note that
`generate_appcast` only rewrites an entry when the archive's bytes change, so
editing notes for an already-signed version means deleting `docs/appcast.xml` and
regenerating.

`Package.resolved` is committed so Sparkle's version is pinned.

## Releases

Each release has `Sidetone-<version>.dmg`: the signed, notarized and stapled app
with an Applications link to drag it onto.

To publish, raise `VERSION`, write and commit `docs/release-notes/<version>.html`,
push main, write the GitHub release notes in a file outside the repo (or in
`build/`), and run `./publish.sh notes.md` with `SIDETONE_SIGN` set and the
GitHub CLI signed in. It stops unless main is clean and pushed and `v<version>` is
a new tag. Then it runs the checks, builds, has Apple notarize the app with the
notarytool login saved in your Keychain (once, with
`xcrun notarytool store-credentials notary`; set `NOTARY_PROFILE` to use another
name), staples and checks it with `spctl`, and makes the DMG. It signs the appcast with the Sparkle key and checks that the
appcast describes the DMG's exact size, because a mismatch there is invisible until
an update silently fails to install. Finally it commits the appcast to main, pushes
that commit and the tag together, and makes the GitHub release with the notes and
the DMG using the GitHub CLI (`gh auth login` once). GitHub Pages serves the new
appcast from `docs/` on main, and Sparkle picks it up from there.

main takes pull requests only, so the repository admin role has to be in the
ruleset's bypass list for that push to go through.
