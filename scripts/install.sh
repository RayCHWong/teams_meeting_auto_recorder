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

# Checked before building, not after. The build succeeds on an older macOS — it is
# LaunchServices that refuses at launch, with a bare "-10825" that says nothing about why.
REQUIRED_MAJOR=26
CURRENT="$(sw_vers -productVersion)"
if [[ "${CURRENT%%.*}" -lt "$REQUIRED_MAJOR" ]]; then
  cat <<MSG
✗ Meeting Recorder requires macOS $REQUIRED_MAJOR or later. This Mac is running $CURRENT.

  The recording engine itself only needs macOS 14.2 — Core Audio process taps. The macOS $REQUIRED_MAJOR
  floor comes from the Speech framework used for on-device transcription (SpeechAnalyzer,
  which does not exist before $REQUIRED_MAJOR).

  Building anyway will work; installing will not. LaunchServices refuses the app with
  error -10825 (incompatible system version) because Info.plist declares
  LSMinimumSystemVersion $REQUIRED_MAJOR.0.

  If you need this on an older macOS, transcription has to be made optional and gated —
  open an issue rather than lowering LSMinimumSystemVersion by hand, which only moves
  the failure to the first transcription attempt.
MSG
  exit 1
fi

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
