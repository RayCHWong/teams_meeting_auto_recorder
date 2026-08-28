# Teams Meeting Auto-Recorder — Build Plan (Swift)

**Target platform:** macOS 26.5, single user, local only
**Stack:** Swift 6 · SwiftUI · Core Audio process taps · EventKit
**Status:** specification, not yet started
**Audience:** an engineer or coding agent implementing this end to end

---

## How to use this document

This is a complete build spec. Work the phases in order. Each phase ends with a
**Gate** — a verification step that must pass before moving on.

The gates are not ceremony. macOS audio capture fails *silently* in at least four
distinct ways documented below: the API returns success, the callback fires on
schedule, the file is valid, and every sample is zero. A recording that "worked" is
not evidence of anything until something has checked the actual sample values.

Where a decision is marked **locked**, it was made deliberately and the reasoning is
given. Don't re-litigate those without checking with the project owner.

Section 16 is marked **for the owner, not the implementer** — those need a human
decision before the tool is used in earnest.

---

## 1. Goal

Automatically record the audio of Microsoft Teams meetings on macOS. Start when the
user actually joins a call, stop when they leave, capture the local microphone and the
far-end audio as separate tracks, and name each recording from the matching calendar
event. Provide a menu bar UI for live status and manual control, a library window for
playback, and notifications on start and stop.

Personal tool for one machine. Never distributed, never published, no App Store.

---

## 2. Environment

| Item | Value |
|---|---|
| OS | macOS 26.5 |
| Deployment target | macOS 26.0 |
| Language | Swift 6, strict concurrency |
| UI | SwiftUI, `MenuBarExtra` plus a library `Window` |
| Timezone | `America/Toronto` |
| Teams | New Teams client, bundle id `com.microsoft.teams2` |
| Calendar | Work calendar is present in the Mac Calendar app — EventKit is viable |
| Signing | Self-signed or personal team; **stable identity required** (see §3) |
| Recording root | `~/Recordings/Meetings` |

---

## 3. Locked decisions

**Core Audio process taps, not ScreenCaptureKit, and not a virtual audio device.**
Taps operate at the HAL, below the application layer, so they capture audio from
processes with no window presence. They also require only the narrower *System Audio
Recording* permission rather than *Screen & System Audio Recording*. No BlackHole, no
hand-built Aggregate Device, no Multi-Output Device, and no changes to the user's Teams
audio settings.

**Two separate audio tracks, never a pre-mixed file.**
Mic and far-end are written as separate files. Costs nothing now; makes transcription,
speaker attribution, and per-side gain correction possible later. A mixed file cannot
be un-mixed.

**Join detection drives recording; the calendar only labels it.**
Watch `kAudioProcessPropertyIsRunningInput` on the Teams process object. Teams driving
audio input means a call is live. This is more accurate than a calendar window — it
handles joining late, leaving early, skipped meetings, and ad-hoc calls that were never
on the calendar. The calendar is queried at start time only, to name the recording and
attach attendees.

**EventKit, not an ICS feed or Microsoft Graph.**
The work calendar is in the Mac Calendar app. One permission prompt, no published feed,
no tenant policy dependency, no Entra app registration.

**A signed app bundle with a stable identifier is mandatory, not optional.**
TCC keys its permission record to the signing identity. Unsigned builds compile and run
fine but never trigger the permission prompt, so capture silently yields zeros. Run via
Xcode with a real team, or `codesign` against a stable identifier. This is not about
distribution — it is required for the app to function at all.

**`AVCaptureSession` for the microphone, not `AVAudioEngine.installTap`.**
`installTap` has been reported not to fire with Bluetooth input devices on macOS 26.
Given AirPods are likely, use `AVCaptureSession`.

---

## 4. Non-goals

Do not build these.

- Video or screen recording. Audio only.
- Cloud sync, upload, or any network egress of recording content.
- Multi-user support, authentication, or remote access.
- Zoom, Google Meet, or Webex support. The architecture allows adding them later by
  extending the watched-process list; do not do it now.
- Gapless recovery across system sleep — see §9.4.
- Notarization, sandboxing, or App Store compliance.
- A web UI. This appeared in an earlier draft of the plan and is replaced by the
  SwiftUI library window.

---

## 5. Architecture

Single app bundle, `LSUIElement = true`, so no Dock icon. Swift concurrency throughout;
the capture engine is an actor.

```
MeetingRecorderApp.swift     @main, MenuBarExtra + Window scenes
  Coordinator.swift          state machine; the only thing that starts/stops capture
  ProcessMonitor.swift       Core Audio process objects; is-Teams-in-a-call
  TapCapture.swift           tap -> private aggregate device -> IOProc -> file
  MicCapture.swift           AVCaptureSession -> file
  CalendarService.swift      EventKit lookup, Teams-meeting filtering
  RecordingStore.swift       directory layout, meta.json, library scan
  Notifications.swift        UserNotifications wrapper, actions
  Settings.swift             @AppStorage-backed configuration
  Views/                     MenuBarView, LibraryView, SettingsView
```

State machine:

```
IDLE --> ARMED --> RECORDING --> FINALIZING --> IDLE
                       |
                       +-- stopped by user --> IDLE
```

- `ARMED` — Teams is running audio input; waiting out the start debounce.
- `FINALIZING` — Teams audio stopped; waiting out the stop debounce, then closing files.

Debounce: **3 s to start, 20 s to stop.** The stop debounce matters — muting, switching
headsets, or a device change must not end a recording.

---

## 6. Phase 1 — Tap spike (command-line target)

**Build this as a standalone CLI target before any UI exists.** Core Audio is where all
the project risk lives, and you want a print-and-run loop rather than debugging it
through a SwiftUI app with a login item and three permission prompts in the way.

### 6.1 Info.plist — the key Xcode ignores

`NSAudioCaptureUsageDescription` must be added **directly to the Info.plist file**.
Xcode silently drops it when set via the `INFOPLIST_KEY_NSAudioCaptureUsageDescription`
build setting, unlike every other privacy key. If it is missing, TCC denies access
silently and you get zeros with no error anywhere.

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Records the audio of your Teams meetings.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Records your side of your Teams meetings.</string>
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Names recordings after the matching meeting on your calendar.</string>
```

Verify with `plutil -p <bundle>/Contents/Info.plist` after building. Do not assume.

### 6.2 Tap setup sequence

1. Resolve the Teams process: `kAudioHardwarePropertyTranslatePIDToProcessObject`.
2. Build a `CATapDescription` scoped to that process object. Read its `uuid` — it is
   needed for the aggregate device.
   Fall back to `CATapDescription(monoGlobalTapButExcludeProcesses:)`, excluding our own
   process, if the process-scoped tap proves unreliable.
3. `AudioHardwareCreateProcessTap` gives the tap object ID.
4. `AudioHardwareCreateAggregateDevice` with a dictionary containing
   `kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: <tap uuid string>]]` and
   `kAudioAggregateDeviceIsPrivateKey: true`, so it does not appear in system audio
   settings.
5. `AudioDeviceCreateIOProcIDWithBlock`.
6. `AudioDeviceStart`.

A tap alone delivers nothing — it must live inside an aggregate device, and you read
from that device's input stream.

### 6.3 Two ordering rules that cause silent failure

**Start the mic capture session before creating the aggregate device.** With AirPods,
opening the mic forces a Bluetooth profile negotiation from A2DP to HFP. If the
aggregate device is created first, the profile switch happens underneath it and the mic
channel fails silently.

**Host the aggregate device on the built-in output device, not the default output.** The
default output changes when headphones connect or Bluetooth profiles switch, which can
break the aggregate mid-recording. Built-in speakers are always present.

### 6.4 Permission prompt behaviour

There is no `requestAuthorization`-style API for system audio capture. The TCC prompt
fires on `AudioDeviceStart` — not on tap creation, not on aggregate device creation. To
prompt at a convenient moment, build the entire pipeline, start it, hold briefly, then
tear it down.

Every call in the chain returns `noErr` whether or not permission was granted. There is
no error code, no log line, and no way to detect denial except by inspecting sample
values.

To re-test the prompt path after granting or denying:

```bash
tccutil reset SystemAudioCaptureRequests <bundle-id>
```

### 6.5 Non-zero sample check — build this now, not later

Add a helper that computes RMS over the first few seconds of each stream and logs loudly
if it is at or near zero. Wire it into the CLI spike immediately and keep it in the
shipping app. This single check is the difference between finding a permission problem
in ten seconds and finding it in two days.

> **Gate 1 —** With Teams playing audio, the CLI target writes a file whose RMS is
> clearly non-zero, and `plutil -p` confirms `NSAudioCaptureUsageDescription` is present
> in the built bundle. Do not proceed until both hold.

---

## 7. Phase 2 — Join detection

Poll or observe `kAudioProcessPropertyIsRunningInput` on the Teams process object.
`kAudioHardwarePropertyProcessObjectList` enumerates available process objects. Register
a property listener if that proves reliable; otherwise poll at 2 s.

Rules:

- Teams running audio **input** is the join signal. Input specifically — output alone
  fires on notification sounds.
- Start debounce 3 s, stop debounce 20 s.
- If Teams is not running at all there is nothing to watch; re-resolve the process
  object when Teams launches.
- A Teams restart mid-call invalidates the process object. Detect the object going away
  and re-resolve.

> **Gate 2 —** Log transitions while joining a real Teams call, muting and unmuting
> several times, switching audio devices mid-call, then leaving. Exactly one start and
> one stop should be logged.

---

## 8. Phase 3 — Calendar labelling

EventKit. Request access with `requestFullAccessToEvents`.

At recording start, query events overlapping now ± 5 minutes and select the best match:

1. Contains a `teams.microsoft.com/l/meetup-join` URL in the event's URL, location, or
   notes.
2. The user's own participant status is not declined.
3. Not an all-day event.
4. If several match, prefer accepted over tentative, then the nearest start time.

If nothing matches, the recording is still made and labelled `Ad-hoc call`. **A calendar
miss must never prevent or stop a recording** — the calendar is decoration on top of the
audio, not a precondition for it.

EventKit expands recurrence natively via `enumerateEvents(matching:)`. Do not hand-roll
RRULE handling.

> **Gate 3 —** A scheduled Teams meeting produces a correctly titled directory with
> attendees in `meta.json`; an ad-hoc call produces a valid `Ad-hoc call` recording.

---

## 9. Phase 4 — Capture engine and file writing

### 9.1 Writing

Both streams go to AAC in `.m4a` via `AVAudioFile`, written incrementally. Do not buffer
a whole meeting in memory.

- Far-end: stereo, 128 kbps
- Mic: mono, 96 kbps
- Sample rate 48 kHz; resample if the tap format differs

Close files explicitly on stop. On unexpected termination an incrementally written
`.m4a` may be truncated — note this in the recovery rules below.

### 9.2 Output layout

```
~/Recordings/Meetings/2026-08-27_1400_weekly-design-review/
    mic.m4a
    system.m4a
    meta.json
```

Directory name: `YYYY-MM-DD_HHMM_<slug>`. Slugify the title to `[a-z0-9-]`, collapse
repeats, cap at 60 characters, append `-2` on collision.

Write `meta.json` at start and update it at stop. A crash mid-meeting must still leave
identifiable audio.

### 9.3 `meta.json`

```json
{
  "schema": 1,
  "event_id": "0AB3...",
  "title": "Weekly Design Review",
  "organizer": "someone@example.org",
  "attendees": ["a@example.org", "b@example.org"],
  "scheduled_start": "2026-08-27T14:00:00-04:00",
  "scheduled_end": "2026-08-27T15:00:00-04:00",
  "actual_start": "2026-08-27T14:03:11-04:00",
  "actual_end": "2026-08-27T15:02:58-04:00",
  "trigger": "auto",
  "tracks": [
    {"file": "mic.m4a",    "source": "microphone", "rms_ok": true},
    {"file": "system.m4a", "source": "system",     "rms_ok": true}
  ],
  "notes": []
}
```

`trigger` is `auto` or `manual`. `rms_ok` records the non-zero check result. `notes`
collects warnings: sleep restarts, device changes, calendar misses.

### 9.4 Required edge cases

| Case | Required behaviour |
|---|---|
| System sleep / wake | On wake, tear down and rebuild the tap into a new numbered file (`system.002.m4a`). The aggregate device does not reliably survive sleep. Do not attempt gapless recovery; record it in `notes`. |
| Output device change mid-call | The aggregate is pinned to built-in output, so it should survive. Log the change and re-run the RMS check on the next buffer window. |
| Back-to-back meetings | Teams audio usually does not stop between them. If the calendar shows a new event starting and the previous one has ended, close the current recording and open a new one. Never merge two events into one file. |
| Teams restarts mid-call | Re-resolve the process object; restart capture into a numbered file. |
| Low disk space | Check before every start. Refuse below 5 GB and notify. |
| Runaway recording | Hard stop at 4 hours. Notify, and start a new file if audio is still live. |
| Zero-sample stream detected | Fire the failure notification immediately, mid-recording. Do not wait until the meeting ends. |

> **Gate 4 —** A full real meeting, with a sleep and a headset swap during it, produces
> playable tracks with audible audio on both sides and accurate `meta.json`.

---

## 10. Phase 5 — Menu bar UI

`MenuBarExtra` with a status icon for idle, armed, and recording. Use a filled red
indicator while recording — the state must be readable at a glance.

Menu contents:

- Current state and elapsed time while recording
- Meeting title
- **Stop recording** — always available while recording
- **Start recording** — manual, for calls the detector missed
- **Pause auto-recording** for 1 hour / until tomorrow
- Open library
- Open settings

The manual stop is the most important control here. There will be meetings the user
wants to stop recording partway through.

---

## 11. Phase 6 — Library window

A SwiftUI `Window` scene, opened from the menu bar.

- Reverse-chronological list from a disk scan of the recordings root
- Title, date, duration, size, and a warning badge where `rms_ok` is false
- `AVKit` playback for both tracks, independently
- Reveal in Finder
- Delete with confirmation
- Search by title

Read from disk rather than maintaining a separate database. `meta.json` is the source of
truth, and the folder stays usable without the app.

---

## 12. Phase 7 — Notifications

`UserNotifications` — the supported framework, with real notification actions.

| Event | Message | Actions |
|---|---|---|
| Recording started | `Recording — <title>` | Stop |
| Recording stopped | `Saved — <duration>, <size>` | Open, Reveal in Finder |
| Zero-sample detected | `No audio on <track> — check permissions` | Open Settings |
| Failure | `Recording failed: <reason>` | Open log |

The zero-sample and failure notifications are the ones that matter. Silent failure is
the dominant way this kind of tool dies — the user finds out three weeks later that
nothing has recorded since an OS update.

Request authorization at first launch, not at first recording.

---

## 13. Phase 8 — Launch at login

`SMAppService.mainApp.register()`, with a toggle in settings. No launch agent plist, no
`launchctl`.

Add a **daily health check**: on first launch each day, compare yesterday's qualifying
calendar events against recordings on disk and notify if an event had no recording. This
is what catches silent failure.

> **Gate 5 —** Reboot. Confirm the app starts, permissions are intact, and a test call
> records without any prompt appearing.

---

## 14. Phase 9 — Transcription (optional)

macOS 26 ships `SpeechAnalyzer` with the `SpeechTranscriber` module — on-device only,
designed for long-form audio, and materially faster than Whisper large-v3-turbo in
published comparisons. It replaces `SFSpeechRecognizer` and is the right choice here.

- Requires `NSSpeechRecognitionUsageDescription` in Info.plist.
- Run as a post-processing job after `FINALIZING`, not during the call.
- Transcribe the two tracks **separately** — this gives speaker attribution for free,
  the user's track versus everyone else's, with no diarization needed.
- Write `transcript.md` alongside the audio.
- If per-speaker separation within the far-end track is wanted later, `FluidAudio` is
  the commonly used diarization package. Out of scope for now.

---

## 15. Failure modes to design against

Ranked by how likely they are to happen and go unnoticed.

1. **Silent TCC denial** — every Core Audio call returns success, buffers are zeros.
   Caught only by the RMS check (§6.5). This is the single most important defence in the
   project.
2. **Missing `NSAudioCaptureUsageDescription`** — the cause of most instances of #1.
   Verify with `plutil -p` in a build script.
3. **Unsigned build** — no prompt ever fires, capture silently yields zeros.
4. **Bluetooth profile race** — mic silent because the aggregate device was created
   before the mic session. Prevented by the ordering rule in §6.3.
5. **Aggregate device lost after sleep** — prevented by rebuilding on wake.
6. **Detector never fires** — Teams updated and the bundle id or process behaviour
   changed. Caught by the daily health check.

---

## 16. For the owner, not the implementer

Three decisions a coding agent cannot make.

**Consent and disclosure.** Canadian one-party-consent rules mean recording a
conversation you are part of is legal, but that is the floor. Employer policy, the Teams
tenant's own recording policy, and any PHIPA exposure in what gets discussed all sit
above it — and silently recording colleagues carries a social cost even where it is
permitted. If disclosure is chosen, the visible menu bar indicator and manual stop are
already in this plan. Check with the relevant policy owner. This is not legal advice.

**Encryption at rest.** If meeting content could touch patient or learner information,
confirm FileVault is enabled at minimum. Consider placing the recordings root on an
encrypted sparse bundle.

**Retention period.** How long recordings are kept, and whether an automatic deletion
job should enforce it. Decide before the first recording, not after a year of
accumulation.

---

## 17. Effort estimate

| Phase | Estimate |
|---|---|
| 1 — Tap spike | 1–2 days. Core Audio is a C API with unhelpful failure modes; expect this to feel unproductive. |
| 2 — Join detection | Half a day |
| 3 — Calendar | 2–3 hours; EventKit is straightforward |
| 4 — Capture engine | 1 day |
| 5 — Menu bar UI | Half a day |
| 6 — Library window | Half a day |
| 7 — Notifications | 2 hours |
| 8 — Launch at login | 1 hour |
| 9 — Transcription | Half a day |

Phases 1–5 make a working tool. Phase 1 is most of the risk and should be timeboxed: if
the process-scoped tap resists after a day, fall back to the global tap with
self-exclusion and move on.

---

## 18. Reference

- `insidegui/AudioCap` — working sample code for Core Audio process taps:
  <https://github.com/insidegui/AudioCap>
- *2,000 Buffers of Nothing* — the Info.plist and silent-denial traps, written by a
  developer who hit all of them:
  <https://www.thunderkitty.app/learn/2000-buffers-of-nothing/>
- WWDC25 — *Bring advanced speech-to-text to your app with SpeechAnalyzer*:
  <https://developer.apple.com/videos/play/wwdc2025/277/>
