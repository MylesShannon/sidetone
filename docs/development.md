# Development

Needs a Swift 6 toolchain, from either Xcode or the Command Line Tools.

| Command        | Result                                                 |
| -------------- | ------------------------------------------------------ |
| `make app`     | Build and assemble `.dist/Sidetone.app`                 |
| `make run`     | Build, assemble, and launch                             |
| `make install` | Copy to `/Applications` and relaunch                    |
| `make test`    | Run the checks                                          |
| `make icon`    | Rebuild `AppIcon.icns` from `Resources/AppIcon.png`     |
| `make dmg`     | Build a DMG, not notarized                              |
| `make release` | Build a signed, notarized, stapled DMG                  |

## Signing

Run `make cert` once. It creates a self-signed "Sidetone Local" identity that
builds pick up automatically.

This is not about Gatekeeper, which trusts neither ad-hoc nor self-signed builds.
It is about the designated requirement. An ad-hoc signature produces one pinned to
the hash of that exact binary:

```
designated => cdhash H"7c463a92…" or cdhash H"b6e9e321…"
```

macOS keys microphone permission and login item registration to that requirement,
so every build is a different app as far as those are concerned. With a stable
identity the requirement becomes `identifier "com.mshannon.sidetone" and
certificate leaf = H"…"`, which survives a new version.

That matters most for updates. Sparkle replaces the app in place, and without a
stable identity the new version can arrive unrecognised: microphone prompt again,
login item silently broken. Use the same certificate for every release, and back it
up, because losing it resets those permissions for everyone.

Keep the exported bundle. `make cert-export` writes `.dist/signing-identity.p12`
while the identity is being made, and that is the only copy that will ever exist: a
key already in the keychain cannot be exported afterwards. The certificate was
replaced once, between 1.1.0 and the release after it, because that copy had been
deleted and CI needed the key. Everyone who updates across that boundary is asked
for microphone permission once more.

The hardened runtime is off for these builds, and must stay off. It enables library
validation, which requires embedded frameworks to carry the same Team ID as the app.
A self-signed certificate has no Team ID, so Sparkle fails to load and the app does
not start. Only a Developer ID has a team, and only notarization needs the hardened
runtime, so `make-app.sh` enables it for Developer ID signing alone and fails the
build if a bundle ends up hardened without a team.

## Tests

`swift test` is not used. The Command Line Tools SDK ships neither XCTest nor
swift-testing, so a machine without a full Xcode install cannot run a normal test
target. The `Verify` executable covers the same ground with a small assertion
harness: ring buffer behaviour, resampling, drift control, gain and limiting,
metering, the FFT band mapping, latency profiles, settings migration, the feedback
rule, device resolution across a replug, hardware failure messages, and the
configuration change filter.

`make test` builds `Verify` and then runs the binary, rather than using
`swift run`. On GitHub's macOS runners `swift run` is killed with SIGKILL the moment
it launches the freshly signed binary. Running it directly works.

If the toolchain refuses to build because Xcode is installed but its license was
never accepted, run `sudo xcodebuild -license accept`.

## Version numbers

The version comes from the `VERSION` file, and `Scripts/make-app.sh` substitutes
it into `Resources/Info.plist` while assembling the bundle, so nothing is
hardcoded in Swift. `CFBundleVersion` gets the same string as
`CFBundleShortVersionString`: there is no separate build number, because nothing
here needs one. An updater framework would, since those rely on a value that
always increases.

## Universal builds

`make dmg` and `make release` build for both architectures so Intel Macs are not
excluded. `make app` stays native, since building twice for local work only costs
time.

SwiftPM's `--arch arm64 --arch x86_64` needs Xcode's build system, which a Command
Line Tools install does not have. `Scripts/make-app.sh` therefore builds each slice
into its own scratch directory and joins them with `lipo`. Sparkle's framework is
already universal, so it is copied as-is.

## Updates

Sparkle handles updates: it reads `docs/appcast.xml`, compares versions, shows its
own dialog, downloads, verifies, installs, and relaunches. `Resources/Info.plist`
carries `SUFeedURL` and `SUPublicEDKey`.

The private half of that key pair lives in the login keychain, put there by
Sparkle's `generate_keys`. **Back it up.** Without it no future release can be
signed, and installs already in the wild have no way to update.

Release notes live in `docs/release-notes/<version>.html` and are copied next to the
DMG so `generate_appcast` embeds them. Without one, the update dialog offers a
version number and nothing else. Note that `generate_appcast` only rewrites an
entry when the archive's bytes change, so editing notes for an already-signed
version means deleting `docs/appcast.xml` and regenerating.

`make dmg` regenerates and signs the appcast automatically. Publishing means
committing `docs/appcast.xml` and serving it from GitHub Pages at the `SUFeedURL`
above, with the DMG attached to a GitHub release tagged `v<version>` so the
enclosure URL resolves.

Sparkle is embedded as a framework in `Contents/Frameworks`, and
`Scripts/make-app.sh` signs its updater app and both XPC services from the inside
out before signing the app itself. `Package.resolved` is committed so the version
is pinned.

## CI

`.github/workflows/ci.yml` runs on every push to any branch and on pull requests:
checks, a universal build, a confirmation that both architectures are present, and
the DMG attached to the run as an artifact for 30 days. Actions is free on public
repositories, macOS runners included.

That artifact is how a change gets tried before it is merged. Push a branch, open
the run, and the DMG is at the bottom, named for the branch and the commit. A new
push cancels the build it replaces, since only the newest one is any use.

Those builds are signed with the same certificate the releases use, held as a
repository secret as well as in the release environment, so installing one is not
installing a different app: microphone permission and the login item survive. A
pull request from a fork gets no secrets and so gets an ad-hoc signature instead,
which the build says out loud rather than failing over.

CI builds with `SIDETONE_SKIP_APPCAST=1`, because it has no signing key and an
unsigned appcast is worse than none. Those artifacts are for trying a build, not
for handing to anyone: they are ad-hoc signed, so installing one and then a real
release looks like two different apps to macOS and resets microphone permission.

The workflows pin `macos-15`. SwiftUI gates behaviour on the SDK an app was built
against rather than the macOS running it, and against newer SDKs a menu bar window
that has been re-sized is afterwards laid out at its ideal size, where anything
flexible shrinks to its own content. That is why the panel's controls take fixed
widths from `Metrics` instead of filling. Building locally against the older SDK to
compare is not possible: `SDKROOT` pointed at `MacOSX15.sdk` fails in the `Observable`
macro, so it needs the older Xcode.

## Releasing from CI

Pushing a `v*` tag runs `.github/workflows/release.yml`, which builds and signs a
universal app, packages the DMG, re-signs the appcast, commits it to `main` so Pages
serves it, and creates the GitHub release with generated notes.

It refuses to run if the tag disagrees with the `VERSION` file, and refuses to
publish if the appcast's stated byte count does not match the DMG being uploaded.
That second check exists because a mismatch there is invisible until an update
silently fails to install.

That commit to `main` needs a way past the ruleset, which takes pull requests only.
A personal repository can name two kinds of thing in a ruleset's bypass list: an
admin, and a deploy key. The Actions token is neither, so the appcast push goes over
SSH as a deploy key held in `APPCAST_DEPLOY_KEY`. A GitHub App would be the usual
answer and is rejected here for want of an organisation to install it in.

### The four secrets

These belong to a **`release` environment** rather than the repository, so a
required reviewer stands between pushing a tag and the keys being readable.

| Secret | Where it comes from |
| ------ | ------------------- |
| `SPARKLE_PRIVATE_KEY` | `.build/artifacts/sparkle/Sparkle/bin/generate_keys -x key.txt` then the file contents |
| `SIGNING_CERT_P12` | `security export -k login.keychain-db -t identities -f pkcs12 -P <password> -o identity.p12`, then `base64 -i identity.p12 \| pbcopy` |
| `SIGNING_CERT_PASSWORD` | the password chosen during that export |
| `APPCAST_DEPLOY_KEY` | `ssh-keygen -t ed25519`, the public half added as a repository deploy key with write access, the private half here |

Delete the exported files afterwards. The Sparkle export in particular is
equivalent to the key itself.

### What this is trusting

That Sparkle key authorises code to replace itself on other people's machines.
Anyone with write access to this repository, or any compromised action it runs, can
sign an update with it. The mitigations are the approval gate on the `release`
environment, `permissions: contents: write` and nothing wider, and pinning every
action to a commit SHA rather than a moving tag. The workflow currently uses tags
for readability, which is the weakest link in it.

If that trade ever stops feeling worth it, delete the secrets and run `make dmg`
locally instead. Everything else keeps working.

## Releases

`make dmg` is the one that works without paying Apple. It builds the app, stages
it with an Applications symlink, and produces `.dist/Sidetone-<version>.dmg`. The
result is signed with whatever local identity is available, which no other machine
trusts, so anyone who downloads it has to allow the app once in System Settings
under Privacy & Security. There is no way around that without notarization, and
the README tells users what to expect.

Nothing is stopping you shipping that DMG. It is only worth knowing that a share
of people will read the Gatekeeper warning as "this app is broken" and give up,
which is the entire reason notarization exists.

`make release` builds a signed, notarized, stapled DMG instead. It needs a paid
Apple Developer membership. Store the notarization credential once:

```sh
xcrun notarytool store-credentials SIDETONE_NOTARY \
    --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Then:

```sh
export SIDETONE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export SIDETONE_KEYCHAIN_PROFILE="SIDETONE_NOTARY"
make release
```

Without those variables the script says which one is missing and stops, rather
than producing an artifact that only looks notarized.
