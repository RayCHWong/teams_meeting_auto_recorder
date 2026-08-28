#!/bin/bash
# Creates a self-signed code-signing identity so TCC has a STABLE identity to key
# permissions to. Without this, every rebuild changes the cdhash, TCC forgets the
# grant, and capture silently returns zeros (plan.md §3, §15.3).
#
# Idempotent: does nothing if the identity already exists.
set -euo pipefail

CN="Teams Meeting Auto-Recorder Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -v -p codesigning | grep -q "$CN"; then
  echo "Identity already present: $CN"
  security find-identity -v -p codesigning | grep "$CN"
  exit 0
fi

echo "Generating self-signed code-signing certificate: $CN"
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$CN" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1

openssl pkcs12 -export -legacy -out "$TMP/id.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:tmr >/dev/null 2>&1

security import "$TMP/id.p12" -k "$KEYCHAIN" -P tmr \
  -T /usr/bin/codesign -T /usr/bin/security -A

# Trust it for code signing in the *user* trust domain (no sudo, no admin domain).
# It is a self-signed root, so -r trustRoot; -r trustAsRoot is rejected here.
security find-certificate -c "$CN" -p "$KEYCHAIN" > "$TMP/in-keychain.pem"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/in-keychain.pem"

# Let codesign use the key without an interactive prompt on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || \
  echo "note: set-key-partition-list needs your login password; codesign may prompt once and you can click 'Always Allow'"

echo
security find-identity -v -p codesigning
