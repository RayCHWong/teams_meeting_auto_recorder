# Teams Meeting Auto-Recorder

A macOS menu bar app that records the audio of your Microsoft Teams meetings automatically.
It starts when you actually join a call, stops when you leave, and names each recording from
the matching calendar event.

Everything runs locally. No cloud, no accounts, no network egress — including the transcription.

> **Recording other people has rules.** One-party consent is the legal floor in some
> jurisdictions and not the answer anywhere. Your employer's policy, your Teams tenant's own
> recording policy, and any regulated data discussed in the meeting all sit above it — and
> silently recording colleagues carries a social cost even where it is permitted. The menu bar
> shows a visible recording indicator and a manual stop for this reason. Check with whoever owns
> the relevant policy. This is not legal advice.

---

## What it does

- **Detects calls, not calendar slots.** Recording is driven by Teams actually pulling from an
  audio input device, so it handles joining late, leaving early, meetings you skip, and ad-hoc
  calls that were never scheduled.
- **Captures both sides.** Your microphone and the far end are captured separately and combined
  into one file afterwards. You can keep the separate tracks instead, or both.
- **Names recordings from your calendar.** Matched against Teams meetings in the macOS Calendar
  app, with attendees recorded alongside. A calendar miss never prevents a recording.
- **Transcribes on device.** Optional, after the call, using Apple's Speech framework — either
  the long-form model or the model behind macOS Dictation, whichever suits the language.
- **Records in-person meetings too.** Microphone only, with a name you type up front.
- **Tells you when it is failing.** The most likely failure is a recording that contains perfect
  silence, so the app measures its own output continuously and says so — mid-recording, not
  afterwards.
- **Survives the awkward cases.** System sleep, headset swaps, Teams restarts, back-to-back
  meetings, low disk, runaway recordings, and app crashes mid-processing.

## Requirements

- macOS 26 or later
- Xcode Command Line Tools (`xcode-select --install`) — **Xcode itself is not required**.
  Check with `swift --version`; built and tested against Swift 6.3.
- Microsoft Teams (the current client, `com.microsoft.teams2`)

## Install

```bash
git clone https://github.com/RayCHWong/teams_meeting_auto_recorder.git
cd teams_meeting_auto_recorder
make cert      # once — creates a self-signed code-signing identity in your login keychain
make install   # builds, installs to /Applications, and launches
```

`make cert` triggers one keychain prompt the first time `codesign` uses the new key — choose
**Always Allow**.

Then open **Settings** from the menu bar and enable **Launch at login**.

### Why it needs a signing identity

macOS keys permissions to an app's signing identity. An unsigned build compiles, runs, reports
success on every call, and captures nothing but silence. The self-signed certificate gives the
app a stable identity so permission grants survive rebuilds. It is not about distribution.

### Permissions

On first run macOS will ask for:

| Permission | Why |
|---|---|
| **System audio recording** | The far end of the call. Without it every recording is silent. |
| **Microphone** | Your side of the call. |
| **Calendar** | Names recordings after the matching meeting. Optional — recordings are named `ad-hoc meeting` without it. |

The system audio prompt appears the first time a recording starts, and capture waits until you
answer it. Settings has a **Test** button that plays a tone and listens for it, so you can
confirm the permission works without waiting for a meeting.

## Using it

The menu bar icon shows the current state and the elapsed time while recording.

| Action | What it does |
|---|---|
| *(automatic)* | Recording starts ~3 s after you join a Teams call and stops ~20 s after you leave |
| **Stop Recording** | Ends the current recording immediately |
| **Start Recording** | For a call the detector missed |
| **Record In-Person Meeting** | Asks for a name, then captures the microphone only |
| **Pause Auto-Recording** | For an hour, or until tomorrow |
| **Library** | Browse, play, rename, and delete recordings |

## What you get

```
~/Recordings/Meetings/2026-08-27_1400_weekly-design-review/
    recording.m4a              both sides, combined
    meta.json                  title, attendees, timings, per-track silence check
    transcript.md              optional — the transcript text, nothing else
    original sound tracks/     the raw sides, if you choose to keep them
        mic.m4a                your side, mono 96 kbps
        system.m4a             the far end, stereo 128 kbps
```

`meta.json` is the source of truth. The library reads it off disk, so the folder stays useful
without the app.

## Settings

- **Save as** — one combined file, the separate tracks, or both
- **Transcription** — on/off, model (Automatic / Long-form / Dictation), and spoken language
- **Launch at login**, recordings folder, runaway-recording limit
- **Permissions** panel with a live system-audio test

## How it works

Four decisions carry the design. Reversing any of them breaks the app in ways that are hard to
see, so they are worth knowing before changing anything.

**Core Audio process taps** — not ScreenCaptureKit, not a virtual audio device. Taps run at the
HAL, below the application layer, so they capture from processes with no window presence, and
they need only the narrower *System Audio Recording* permission. No BlackHole, no manual
Aggregate Device, no changes to your Teams audio settings.

**Separate capture, combined afterwards.** The microphone and the tap have no shared clock and
drift apart over an hour, so summing them in the realtime path risks corrupting the only copy.
They are mixed after the call instead, which also means a crash mid-meeting still leaves usable
audio.

**Join detection drives recording; the calendar only labels it.** Teams pulling from an input
device means a call is live — more reliable than any calendar window.

**A stable signing identity is mandatory.** See above.

### The failure this is built around

Every Core Audio call in the capture chain returns `noErr` whether or not permission was
granted. A denied tap produces a valid `.m4a` in which every sample is zero — no error code, no
log line, nothing to distinguish it from a good recording except the sample values.

So the app measures its own output. RMS is checked on every buffer, written into `meta.json` as
`rms_ok`, surfaced as a live meter in the menu, and reported **during** the recording rather than
at the end. A daily health check compares yesterday's meetings against what is actually on disk,
because the other way this kind of tool dies is quietly, after an OS update, weeks before anyone
notices.

## Diagnostics

`TapSpike` is the harness the capture path was built with. Same engine as the app, print
statements instead of a menu bar.

```bash
make spike
build/TapSpike.app/Contents/MacOS/TapSpike <command>
```

| Command | What it does |
|---|---|
| `list` | Every Core Audio process object, and which are using audio input |
| `record` | Capture and run the non-zero sample check |
| `permission` | Play a tone and listen for it — verifies system audio capture |
| `watch` | Log call join/leave transitions |
| `session` | A full recording including `meta.json` |
| `calendar` | What EventKit can actually see |
| `speech` | Compare the two speech models and their installed languages |
| `mix <dir>` | Re-combine an existing recording |
| `transcribe <dir>` | Re-transcribe an existing recording |

## Known limitations

- **macOS will not deliver notifications** for a locally-signed app like this one —
  `requestAuthorization` returns `notificationsNotAllowed`, plain and provisional. Alerts go to
  the menu bar icon, a floating panel, the library, and `alerts.log` instead. Signing with a
  Developer ID should restore notifications with no code change.
- **The transcription language is manual.** There is no language-identification API in the Speech
  framework, so a meeting in a language other than the one selected will produce nonsense.
  Change it in Settings.
- **Teams only.** Adding Zoom or Meet means extending one list of bundle-id prefixes, but it has
  not been done or tested.
- **Not notarized, not sandboxed, no App Store.** You build it yourself.

## Project layout

```
Sources/RecorderKit/       the engine — capture, detection, storage, mixing, transcription
Sources/MeetingRecorder/   the SwiftUI app — menu bar, library, settings
Sources/TapSpike/          the command-line diagnostic harness
scripts/                   signing, bundle assembly, install
plan.md                    the original build specification
```

`scripts/build-app.sh` assembles and signs the `.app` by hand rather than using Xcode. That is
deliberate: the two things Xcode would do here are the two it gets wrong for this app — it
silently drops `NSAudioCaptureUsageDescription` when set as a build setting, and a default local
build has no stable signing identity.

## License

MIT — see [`LICENSE`](LICENSE).

## References

- [`insidegui/AudioCap`](https://github.com/insidegui/AudioCap) — working sample code for Core
  Audio process taps
- [*2,000 Buffers of Nothing*](https://www.thunderkitty.app/learn/2000-buffers-of-nothing/) — the
  Info.plist and silent-denial traps, first-hand
- [WWDC25 — Bring advanced speech-to-text to your app with SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
