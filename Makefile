.PHONY: help cert build app spike install verify list watch record session gates clean

SPIKE := build/TapSpike.app/Contents/MacOS/TapSpike

help:
	@echo "Teams Meeting Auto-Recorder"
	@echo
	@echo "  make cert       create the self-signed code-signing identity (once)"
	@echo "  make app        build + sign build/MeetingRecorder.app"
	@echo "  make spike      build + sign build/TapSpike.app (the diagnostic harness)"
	@echo "  make install    release build, install to /Applications, launch"
	@echo "  make verify     check the built bundle's Info.plist and signature"
	@echo
	@echo "  make list       enumerate Core Audio process objects"
	@echo "  make record     Gate 1 — capture Teams audio and check for non-zero samples"
	@echo "  make watch      Gate 2 — log call join/leave transitions"
	@echo "  make session    Gates 3-4 — a full recording incl. meta.json"
	@echo "  make gates      what each gate needs and how to run it"

cert:
	./scripts/make-signing-cert.sh

build:
	swift build

app:
	./scripts/build-app.sh MeetingRecorder

spike:
	./scripts/build-app.sh TapSpike

install:
	./scripts/install.sh

# The two checks that stand between a working recorder and one that silently writes silence.
verify: app
	@plutil -p build/MeetingRecorder.app/Contents/Info.plist | grep -E "NSAudioCapture|NSMicrophone|NSCalendars" \
		|| (echo "✗ privacy usage strings missing from the built bundle"; exit 1)
	@codesign -dv build/MeetingRecorder.app 2>&1 | grep -E "Identifier|Authority"
	@echo "✓ Info.plist and signature look right"

list: spike
	@$(SPIKE) list

record: spike
	@$(SPIKE) record --seconds 15

watch: spike
	@$(SPIKE) watch

session: spike
	@$(SPIKE) session --seconds 20

gates:
	@echo "Gate 1  make record          — needs Teams playing audio. Passes on non-zero RMS."
	@echo "Gate 2  make watch           — join a real call, mute/unmute, swap headsets, leave."
	@echo "                               Expect exactly one RECORDING and one IDLE."
	@echo "Gate 3  make session         — a scheduled Teams meeting must name the directory"
	@echo "                               correctly and list attendees in meta.json."
	@echo "Gate 4  (a real meeting)     — sleep the Mac and swap a headset mid-call, then check"
	@echo "                               both tracks are audible and meta.json is accurate."
	@echo "Gate 5  make install; reboot — the app starts, permissions are intact, and a test"
	@echo "                               call records with no prompt."

clean:
	swift package clean
	rm -rf build
