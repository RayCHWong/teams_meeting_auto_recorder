#!/bin/bash
# Assembles a signed .app bundle from a SwiftPM product.
#
# There is no Xcode on this machine — Command Line Tools only — so the bundle is built by
# hand. That is not a workaround: the two things Xcode would do for us here are exactly the
# two things plan.md §6.1 and §3 warn it gets wrong (dropping NSAudioCaptureUsageDescription,
# and signing with an identity that changes between builds).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

PRODUCT="${1:-MeetingRecorder}"
CONFIG="${CONFIG:-debug}"
IDENTITY="${SIGNING_IDENTITY:-Teams Meeting Auto-Recorder Dev}"
APP="$ROOT/build/$PRODUCT.app"
PLIST="$ROOT/Resources/$PRODUCT-Info.plist"

[[ -f "$PLIST" ]] || { echo "no Info.plist template at $PLIST"; exit 1; }

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "✗ No code-signing identity '$IDENTITY'. Run scripts/make-signing-cert.sh first."
  echo "  Without a stable identity TCC re-prompts on every build, and an unsigned build"
  echo "  never prompts at all — it just captures silence (plan.md §3, §15.3)."
  exit 1
fi

echo "▸ swift build --configuration $CONFIG --product $PRODUCT"
swift build --configuration "$CONFIG" --product "$PRODUCT"
BIN="$(swift build --configuration "$CONFIG" --show-bin-path)/$PRODUCT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$PRODUCT"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ codesign --sign '$IDENTITY'"
codesign --force --sign "$IDENTITY" --timestamp=none \
  --identifier "$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")" \
  "$APP" >/dev/null

# Verify rather than assume — both traps that produce a silent all-zero capture.
MISSING=0
for KEY in NSAudioCaptureUsageDescription NSMicrophoneUsageDescription NSCalendarsFullAccessUsageDescription; do
  if ! plutil -extract "$KEY" raw "$APP/Contents/Info.plist" >/dev/null 2>&1; then
    echo "✗ $KEY missing from the BUILT bundle"; MISSING=1
  fi
done
[[ $MISSING -eq 0 ]] || exit 1

codesign --verify --strict "$APP"
echo "✓ $APP"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Authority|Signature" || true
