#!/bin/bash
# Builds a release app and installs it to /Applications.
#
# The install location matters for launch-at-login: SMAppService registers the app by path,
# so an app that lives in a build directory gets unregistered the moment that directory is
# cleaned. TCC permissions survive the move, because they are keyed to the signing identity
# and bundle id rather than the path (plan.md §3).
set -euo pipefail

cd "$(dirname "$0")/.."
DEST="/Applications/Meeting Recorder.app"

CONFIG=release ./scripts/build-app.sh MeetingRecorder

if pgrep -x MeetingRecorder >/dev/null; then
  echo "▸ quitting the running copy"
  osascript -e 'tell application id "com.raywong.MeetingRecorder" to quit' 2>/dev/null || pkill -x MeetingRecorder || true
  sleep 1
fi

echo "▸ installing to $DEST"
rm -rf "$DEST"
cp -R build/MeetingRecorder.app "$DEST"

# Re-sign in place: copying can disturb the signature, and an invalid signature means TCC
# treats this as a different app and silently forgets every permission.
codesign --force --sign "${SIGNING_IDENTITY:-Teams Meeting Auto-Recorder Dev}" \
  --identifier com.raywong.MeetingRecorder "$DEST" >/dev/null
codesign --verify --strict "$DEST"

echo "▸ launching"
open "$DEST"
echo "✓ installed and running — look for the waveform icon in the menu bar"
echo "  Enable 'Launch at login' in Settings to finish Phase 8."
