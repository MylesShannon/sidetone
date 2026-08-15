#!/bin/bash
# Create a self-signed code signing identity called "Sidetone Local".
#
# This does nothing for Gatekeeper: no other machine trusts a self-signed
# certificate. What it does is give every build the same code identity, so the
# designated requirement stops being a hash of one particular binary. macOS keys
# microphone permission and login item registration to that requirement, which
# means without a stable identity a Sparkle update can land as a different app and
# lose both.
#
# Back the certificate up once it exists. Losing it resets those permissions for
# everyone running Sidetone.
set -euo pipefail

NAME="Sidetone Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# --export <path> keeps a copy of the PKCS12 bundle, which is what CI needs as a
# secret. It is written while the identity is being created, because a key in the
# keychain cannot reliably be exported afterwards: 'security export' works on every
# identity at once and fails on any that a device management profile marked
# non-exportable.
EXPORT_PATH=""
if [[ "${1:-}" == "--export" ]]; then
	EXPORT_PATH="${2:?--export needs a path}"
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
	if [[ -n "$EXPORT_PATH" ]]; then
		cat >&2 <<EOF
'$NAME' already exists, and its key cannot be exported after the fact.

To get an exportable copy, remove the existing one and create it again:

    security delete-identity -c "$NAME"
    make cert-export

Nothing has been released with the current certificate yet, so replacing it costs
nothing. Once a release exists, replacing it resets microphone permission for
anyone who updates.
EOF
		exit 1
	fi
	echo "'$NAME' already exists, nothing to do"
	exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The keychain importer rejects a PKCS12 bundle that has no password. When the
# bundle is being kept for CI the password matters, so it can be set.
PASS="${SIDETONE_P12_PASSWORD:-sidetone-import}"

echo "==> generating a self-signed code signing certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
	-keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
	-subj "/CN=$NAME" \
	-addext "basicConstraints=critical,CA:false" \
	-addext "keyUsage=critical,digitalSignature" \
	-addext "extendedKeyUsage=critical,codeSigning"

export_bundle() {
	openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
		-out "$WORK/identity.p12" -passout "pass:$PASS" "$@"
}

# OpenSSL 3 defaults to algorithms the keychain cannot read and needs -legacy.
# LibreSSL, which is what macOS ships, has no such flag and needs no help.
export_bundle || export_bundle -legacy

if [[ -n "$EXPORT_PATH" ]]; then
	cp "$WORK/identity.p12" "$EXPORT_PATH"
	chmod 600 "$EXPORT_PATH"
	echo "==> wrote $EXPORT_PATH (password: $PASS)"
fi

echo "==> importing into the login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

echo "==> trusting it for code signing"
echo "    macOS will ask for your password."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# Without this codesign fails with errSecInternalComponent, or stops to ask
# permission on every build. Importing with -T is not enough on its own.
echo "==> letting codesign use the key"
echo "    macOS will ask for your login password again."
security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" >/dev/null

if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
	echo "error: the certificate imported but no code signing identity appeared." >&2
	echo "       Check 'security find-identity -v -p codesigning'." >&2
	exit 1
fi

cat <<EOF

'$NAME' is ready. Builds pick it up automatically from here on.

The first build will ask for permission to use the key. Choose "Always Allow" or
every build will ask again.
EOF
