import AVFoundation
import CoreAudio
import Foundation
import RecorderKit
import Speech

// Phase 1 diagnostic harness (plan.md §6). Everything the app does to get audio out of
// another process, with print statements instead of a menu bar — because Core Audio is a C
// API whose failure mode is silence, and you want a print-and-run loop while you find that out.
//
//   tapspike list                 what the HAL can see, and who is making noise right now
//   tapspike record [options]     Gate 1: capture, then prove the samples are not all zero
//   tapspike watch                Gate 2: log join/leave transitions
//   tapspike session              Gates 3+4: a full RecordingSession, meta.json and all
//   tapspike transcribe <dir>     Phase 9: transcribe a finished recording directory
//   tapspike plist                verify NSAudioCaptureUsageDescription survived the build

let arguments = CommandLine.arguments
let command = arguments.count > 1 ? arguments[1] : "record"

func flag(_ name: String) -> Bool { arguments.contains("--\(name)") }
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

// Prefixes, not exact ids: the HAL only ever shows Teams' child processes.
let teamsBundlePrefixes = ["com.microsoft.teams2", "com.microsoft.teams"]

func describe(_ object: AudioObjectID) -> String {
    let bundle = ProcessResolver.bundleID(of: object) ?? "—"
    let pid = ProcessResolver.pid(of: object).map(String.init) ?? "—"
    let input = ProcessResolver.isRunningInput(object) ? "IN " : "   "
    let output = ProcessResolver.isRunningOutput(object) ? "OUT" : "   "
    return "\(object)".padding(toLength: 8, withPad: " ", startingAt: 0)
        + pid.padding(toLength: 9, withPad: " ", startingAt: 0)
        + input + output + "  " + bundle
}

func resolveTargetProcesses() throws -> [AudioObjectID] {
    if let pidString = option("pid"), let pid = pid_t(pidString) {
        return [try ProcessResolver.processObject(forPID: pid)]
    }
    let prefixes = option("bundle-id").map { [$0] } ?? teamsBundlePrefixes
    let objects = ProcessResolver.processObjects(matchingPrefixes: prefixes)
    guard !objects.isEmpty else { throw RecorderError.teamsNotRunning }
    return objects
}

// MARK: - list

func runList() throws {
    let objects = try ProcessResolver.allProcessObjects()
    print("object   pid      i/o     bundle id")
    print(String(repeating: "-", count: 60))
    for object in objects.sorted() { print(describe(object)) }
    print("\n\(objects.count) process objects. 'IN' means that process is pulling from an input device — that is the join signal.")
}

// MARK: - plist

func runPlist() {
    let info = Bundle.main.infoDictionary ?? [:]
    let required = [
        "NSAudioCaptureUsageDescription",
        "NSMicrophoneUsageDescription",
        "NSCalendarsFullAccessUsageDescription",
    ]
    print("Info.plist as seen at runtime (bundle: \(Bundle.main.bundleIdentifier ?? "none")):")
    var missing = false
    for key in required {
        if let value = info[key] as? String {
            print("  ✓ \(key) = \(value)")
        } else {
            print("  ✗ \(key) MISSING")
            missing = true
        }
    }
    if missing {
        print("""

        A missing NSAudioCaptureUsageDescription is the usual cause of an all-zero capture
        (plan.md §6.1, §15.2). Xcode drops this key when it is set as a build setting rather
        than written into the Info.plist file itself.
        """)
        exit(1)
    }
}

// MARK: - record

func runRecord() throws {
    let seconds = Double(option("seconds") ?? "") ?? 10
    let directory = URL(fileURLWithPath: option("out") ?? "./build/spike", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    // Ordering rule 1 (plan.md §6.3): the mic session comes up BEFORE the aggregate device,
    // or a Bluetooth profile switch happens underneath the aggregate and the mic goes silent.
    var mic: MicCapture?
    var micWriter: AudioFileWriter?
    if !flag("no-mic") {
        let capture = MicCapture()
        if MicCapture.authorizationStatus() != .authorized {
            print("• requesting microphone access…")
            let granted = SyncAwait.run { await MicCapture.requestAccess() }
            print("  microphone access: \(granted ? "granted" : "DENIED")")
        }
        try capture.start()
        guard let micFormat = capture.format else {
            print("! mic delivered no buffers in 3s — continuing without it")
            capture.stop()
            throw RecorderError.noAudioInputDevice
        }
        print("• mic: \(capture.deviceName ?? "?") @ \(Int(micFormat.sampleRate)) Hz, \(micFormat.channelCount) ch")
        let writer = try AudioFileWriter(
            url: directory.appendingPathComponent("mic.m4a"), inputFormat: micFormat, channels: 1, bitRate: 96_000)
        capture.setHandler { [writer] buffer in writer.append(buffer) }
        mic = capture
        micWriter = writer
    }

    let scope: ProcessTap.Scope
    if flag("global") {
        // §6.2 fallback: tap everything except ourselves.
        let ourObject = try? ProcessResolver.processObject(forPID: getpid())
        scope = .globalExcluding(ourObject.map { [$0] } ?? [])
        print("• scope: global tap, excluding self")
    } else {
        let targets = try resolveTargetProcesses()
        for target in targets { print("• target: \(describe(target))") }
        scope = .processes(targets)
    }

    let tap = try ProcessTap(scope: scope, mono: flag("global"), restoreBundleIDs: teamsBundlePrefixes)
    print("• tap format: \(tap.format)")

    let systemWriter = try AudioFileWriter(
        url: directory.appendingPathComponent("system.m4a"),
        inputFormat: tap.format,
        channels: min(2, tap.format.channelCount),
        bitRate: 128_000)

    print("• starting capture for \(Int(seconds))s — the TCC prompt fires now, on AudioDeviceStart")
    try tap.start { [systemWriter] buffer, _ in systemWriter.append(buffer) }

    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        Thread.sleep(forTimeInterval: 1.0)
        let system = systemWriter.meter.consumeWindowRMS()
        let microphone = micWriter?.meter.consumeWindowRMS() ?? 0
        print(String(format: "   %4.0fs  system %7.1f dBFS   mic %7.1f dBFS",
                     Date().timeIntervalSince(started), system.asDecibels, microphone.asDecibels))
    }

    tap.stop()
    mic?.stop()
    systemWriter.close()
    micWriter?.close()
    tap.invalidate()

    print("\n— Gate 1 —")
    var failed = false
    for (label, writer) in [("system", systemWriter), ("mic", micWriter)].compactMap({ pair -> (String, AudioFileWriter)? in
        guard let writer = pair.1 else { return nil }
        return (pair.0, writer)
    }) {
        let rms = writer.meter.rms
        let ok = rms >= LevelMeter.silenceThreshold
        failed = failed || !ok
        let size = ByteCountFormatter().string(fromByteCount: writer.fileSize)
        print("  \(ok ? "✓" : "✗") \(label.padding(toLength: 7, withPad: " ", startingAt: 0))"
            + String(format: "rms %.6f (%.1f dBFS)  peak %.4f  ", rms, rms.asDecibels, writer.meter.peakAmplitude)
            + "\(writer.meter.framesSeen) samples  \(size)")
        print("      \(writer.url.path)")
    }
    if failed {
        print("""

        ✗ At least one stream is all zeros. Every Core Audio call still returned noErr — this
          is exactly the silent failure in plan.md §15. Check, in order:
            1. NSAudioCaptureUsageDescription present in the built Info.plist  (tapspike plist)
            2. the binary is signed with a stable identity                     (codesign -dv)
            3. permission actually granted     (System Settings ▸ Privacy & Security ▸ Audio)
            4. re-arm the prompt: tccutil reset SystemAudioCaptureRequests <bundle-id>
            5. the tapped process was actually making sound during the capture
        """)
        exit(1)
    }
    print("\n✓ Gate 1 passed — non-zero audio on every stream.")
}

// MARK: - session

/// Drives a real `RecordingSession` — the same code path the app uses — against any bundle
/// prefix. Gates 3 and 4 are written around a live Teams meeting, but everything except the
/// join detection can be exercised without one, and a bug found here is a bug not found
/// halfway through a real call.
func runSession() throws {
    let seconds = Double(option("seconds") ?? "") ?? 10
    let prefixes = option("bundle-id").map { [$0] } ?? teamsBundlePrefixes
    let root = URL(fileURLWithPath: option("out") ?? "./build/session-test", isDirectory: true)
    let store = RecordingStore(root: root)

    let calendar = CalendarService()
    let meeting = SyncAwait.run { @Sendable in
        _ = await calendar.requestAccess()
        return calendar.meeting()
    }
    print("• calendar: \(meeting.isAdHoc ? "no match — recording as ad-hoc" : "matched \u{201C}\(meeting.title)\u{201D}")")
    if !meeting.attendees.isEmpty { print("  attendees: \(meeting.attendees.joined(separator: ", "))") }

    let session = try RecordingSession(
        meeting: meeting, trigger: .manual, store: store,
        bundlePrefixes: prefixes, mic: nil)
    session.onSilentStream = { source in print("  ! \(source.rawValue) stream has gone silent") }
    print("• directory: \(session.directory.path)")

    try session.startSegment()
    let started = Date()
    while Date().timeIntervalSince(started) < seconds {
        Thread.sleep(forTimeInterval: 1)
        let levels = session.sampleLevels()
        print(String(format: "   %4.0fs  system %7.1f dBFS   mic %7.1f dBFS",
                     Date().timeIntervalSince(started), levels.system.asDecibels, levels.microphone.asDecibels))
        if flag("simulate-sleep"), Int(Date().timeIntervalSince(started)) == Int(seconds / 2) {
            print("   ↻ simulating a wake-from-sleep segment rebuild")
            try session.startSegment(reason: "resumed after system sleep")
        }
    }

    let metadata = session.finish()
    print("\n— session result —")
    for track in metadata.tracks {
        print("  \(track.rmsOK ? "✓" : "✗") \(track.file)  \(track.source.rawValue)  "
            + String(format: "%.1f dBFS", (track.rms ?? 0).asDecibels))
    }
    for note in metadata.notes { print("  · \(note)") }
    let metaPath = session.directory.appendingPathComponent("meta.json")
    print("\n\(metaPath.path):")
    print((try? String(contentsOf: metaPath, encoding: .utf8)) ?? "<unreadable>")
    if metadata.hasSilentTrack { exit(1) }
}

// MARK: - mix

/// Mixes an already-finished recording directory. Useful for re-mixing after a failure, and
/// for checking the result without waiting for the next meeting.
func runMix() throws {
    guard arguments.count > 2 else {
        print("usage: tapspike mix <recording-directory> [--keep-sources]")
        exit(2)
    }
    let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let store = RecordingStore(root: directory.deletingLastPathComponent())
    guard let metadata = store.readMetadata(in: directory) else {
        print("✗ no meta.json in \(directory.path)")
        exit(1)
    }
    let recording = Recording(directory: directory, metadata: metadata)
    print("• mixing \(metadata.tracks.filter { $0.source != .mixed }.count) source track(s)")
    let updated = SyncAwait.run { @Sendable in
        await RecordingMixer.mixSegments(of: recording, removeSources: !flag("keep-sources"))
    }
    store.writeMetadata(updated, to: directory)
    for track in updated.tracks {
        let path = directory.appendingPathComponent(track.file)
        let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)??.int64Value ?? 0
        print("  \(track.rmsOK ? "✓" : "✗") \(track.file)  \(track.source.rawValue)  "
            + ByteCountFormatter().string(fromByteCount: size))
    }
    for note in updated.notes where note.contains("mix") { print("  · \(note)") }
}

// MARK: - calendar

/// Answers whether EventKit can actually see the work calendar on this Mac — the assumption
/// plan.md §3 rests on when it picks EventKit over Microsoft Graph.
func runCalendar() {
    let service = CalendarService()
    let granted = SyncAwait.run { @Sendable in await service.requestAccess() }
    print("• access: \(granted ? "granted" : "DENIED — approve it in Privacy & Security ▸ Calendars")")
    guard granted else { exit(1) }

    let calendars = service.calendarInventory()
    print("\n\(calendars.count) calendar(s) visible to EventKit:")
    for calendar in calendars {
        print("  · \(calendar.title)   [source: \(calendar.source)]")
    }
    if calendars.isEmpty {
        print("""
          none. No account is configured in the Mac Calendar app, so EventKit has nothing to
          match against and every recording will be named 'Ad-hoc call'.
        """)
    }

    let days = Double(option("days") ?? "") ?? 7
    let now = Date()
    let events = service.rawEvents(from: now.addingTimeInterval(-days * 86400), to: now.addingTimeInterval(days * 86400))
    let teamsEvents = events.filter(\.isTeams)
    print("\n\(events.count) event(s) in ±\(Int(days)) days, \(teamsEvents.count) with a Teams join link:")
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    for event in events.sorted(by: { $0.start < $1.start }).prefix(25) {
        print("  \(event.isTeams ? "T" : " ") \(formatter.string(from: event.start))  \(event.title)   [\(event.calendar)]")
    }
    // What `meeting(at:)` actually resolves to, minute by minute. The match depends on the
    // clock, so a single sample proves nothing: a recording is split when the answer *changes*
    // mid-meeting, and only a sweep shows that. This is how the 2026-09-10 split was confirmed.
    if let at = option("at") {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm"
        parser.timeZone = .current
        guard let centre = parser.date(from: at) else {
            print("\n  --at must look like \"2026-09-10 10:25\"")
            exit(64)
        }
        let span = Int(option("sweep") ?? "0") ?? 0
        print("\nwhat meeting(at:) resolves to\(span > 0 ? ", ±\(span) min" : "") around \(at):")
        var previous: String?
        for offset in -span...span {
            let moment = centre.addingTimeInterval(Double(offset) * 60)
            let info = service.meeting(at: moment)
            let key = "\(info.eventIdentifier ?? "ad-hoc")|\(info.title)"
            if key != previous {
                let window = info.scheduledStart.map { s in
                    let e = info.scheduledEnd ?? s
                    return " [\(formatter.string(from: s))–\(formatter.string(from: e))]"
                } ?? ""
                print("  \(formatter.string(from: moment))  →  \(info.title)\(window)")
                previous = key
            }
        }
        print("  (only changes are printed — one line means the match never flipped)")
    }

    if teamsEvents.isEmpty && !events.isEmpty {
        print("\n  Events exist but none carry a teams.microsoft.com/l/meetup-join link — check that")
        print("  the work account, not just a personal calendar, is connected.")
    }
}

// MARK: - permission

/// Runs the same self-contained probe the Settings window uses.
func runPermission() {
    let store = RecordingStore()
    print("• inferred from recordings: \(SystemAudioPermission.inferred(from: store.allRecordings()))")
    print("• probing (a short tone will play)…")
    let granted = SyncAwait.run { @Sendable in await SystemAudioPermission.probe() }
    print(granted
        ? "✓ system audio capture is working"
        : "✗ captured only silence — system audio permission is denied")
    if !granted { exit(1) }
}

// MARK: - speech

/// Compares the two on-device speech models the Speech framework exposes, and what this Mac
/// actually has installed for each.
func runSpeech() {
    guard #available(macOS 26.0, *) else {
        print("✗ on-device transcription needs macOS 26; recording works without it")
        exit(1)
    }
    if let identifier = option("install") {
        let locale = Locale(identifier: identifier)
        let model = TranscriptionService.Model(rawValue: option("model") ?? "") ?? .automatic
        print("• installing the speech model for \(identifier) (\(model.rawValue))…")
        let result = SyncAwait.run { @Sendable in
            await Result.catchingAsync { try await TranscriptionService.installModel(locale: locale, model: model) }
        }
        switch result {
        case .success(let chosen): print("✓ installed: \(chosen.model.rawValue) / \(chosen.locale.identifier)")
        case .failure(let error): print("✗ \(error.localizedDescription)"); exit(1)
        }
        return
    }

    SyncAwait.run { @Sendable in
        print("SpeechTranscriber (long-form model — what the app uses today)")
        print("  available: \(SpeechTranscriber.isAvailable)")
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales
        print("  supported: \(supported.count) locale(s)")
        print("  installed: \(installed.map(\.identifier).sorted().joined(separator: ", "))")
        print("  supported list: \(supported.map(\.identifier).sorted().joined(separator: ", "))")

        print("\nDictationTranscriber (the model behind macOS Dictation)")
        let dSupported = await DictationTranscriber.supportedLocales
        let dInstalled = await DictationTranscriber.installedLocales
        print("  supported: \(dSupported.count) locale(s)")
        print("  installed: \(dInstalled.map(\.identifier).sorted().joined(separator: ", "))")
        print("  supported list: \(dSupported.map(\.identifier).sorted().joined(separator: ", "))")
    }
}

// MARK: - transcribe

func runTranscribe() throws {
    guard arguments.count > 2 else {
        print("usage: tapspike transcribe <recording-directory>")
        exit(2)
    }
    let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let store = RecordingStore(root: directory.deletingLastPathComponent())
    guard let metadata = store.readMetadata(in: directory) else {
        print("✗ no meta.json in \(directory.path)")
        exit(1)
    }
    let recording = Recording(directory: directory, metadata: metadata)
    guard #available(macOS 26.0, *) else {
        print("✗ on-device transcription needs macOS 26; recording works without it")
        exit(1)
    }
    let model = TranscriptionService.Model(rawValue: option("model") ?? "") ?? .automatic
    let locale = Locale(identifier: option("locale") ?? Locale.current.identifier)
    print("• transcribing \(recording.metadata.tracks.count) track(s) with model=\(model.rawValue) locale=\(locale.identifier)")
    let url = try SyncAwait.run { @Sendable in
        await Result.catchingAsync {
            try await TranscriptionService.transcribe(recording, locale: locale, model: model)
        }
    }.get()
    print("✓ \(url.path)\n")
    print((try? String(contentsOf: url, encoding: .utf8)) ?? "")
}

// MARK: - holdmic

/// Opens the microphone for a while, releases it, and *stays alive* — the shape of leaving a
/// Teams meeting without quitting Teams. Exiting the process instead tests a different path:
/// the target disappearing, which ends a recording immediately with no debounce.
func runHoldMic() throws {
    let hold = Double(option("seconds") ?? "") ?? 12
    let idle = Double(option("idle") ?? "") ?? 30
    let mic = MicCapture()
    try mic.start()
    print("• holding the microphone for \(Int(hold))s  (pid \(getpid()))")
    Thread.sleep(forTimeInterval: hold)
    mic.stop()
    print("• released the microphone; staying alive for \(Int(idle))s")
    Thread.sleep(forTimeInterval: idle)
    print("• exiting")
}

// MARK: - app control

/// Drives the installed app's manual start/stop, so the whole application — coordinator,
/// calendar lookup, alert inbox, meta.json — can be exercised without clicking a menu.
func runApp(_ subcommand: String) {
    let name: Notification.Name
    switch subcommand {
    case "start": name = Coordinator.Command.start
    case "stop": name = Coordinator.Command.stop
    case "calendar": name = Coordinator.Command.dumpCalendar
    case "inperson": name = Coordinator.Command.startInPerson
    case "askinperson": name = Coordinator.Command.askInPerson
    case "settings": name = Coordinator.Command.openSettings
    case "library": name = Coordinator.Command.openLibrary
    default:
        print("usage: tapspike app start|inperson [--title X]|askinperson|stop|settings|library|calendar")
        exit(2)
    }
    let userInfo = option("title").map { ["title": $0] }
    DistributedNotificationCenter.default().postNotificationName(
        name, object: nil, userInfo: userInfo, deliverImmediately: true)
    print("• sent \(subcommand) to Meeting Recorder")
}

// MARK: - watch

func runWatch() throws {
    let prefixes = option("bundle-id").map { [$0] } ?? teamsBundlePrefixes
    let seconds = Double(option("seconds") ?? "") ?? .infinity
    print("Watching \(prefixes.joined(separator: ", ")) for input activity. Ctrl-C to stop.  (Gate 2, plan.md §7)")
    let monitor = ProcessMonitor(bundlePrefixes: prefixes)
    if let stop = Double(option("stop-debounce") ?? "") { monitor.stopDebounce = stop }
    if let start = Double(option("start-debounce") ?? "") { monitor.startDebounce = start }
    monitor.onStateChange = { state in
        let stamp = ISO8601DateFormatter().string(from: Date())
        print("\(stamp)  \(state)")
    }
    monitor.start()

    // Per-process detail: when a call ends but the recording does not, the question is which
    // child process is still holding an input stream. Transitions alone cannot answer that.
    if flag("verbose") {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            let objects = ProcessResolver.processObjects(matchingPrefixes: prefixes)
            let active = objects.filter { ProcessResolver.isRunningInput($0) }
            guard !active.isEmpty else { return }
            let names = active.map { "\(ProcessResolver.bundleID(of: $0) ?? "?")(\($0))" }
            print("        input held by: \(names.joined(separator: ", "))")
        }
    }
    if seconds.isFinite {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        monitor.stop()
    } else {
        RunLoop.main.run()
    }
}

// MARK: - dispatch

do {
    switch command {
    case "list": try runList()
    case "plist": runPlist()
    case "watch": try runWatch()
    case "record": try runRecord()
    case "session": try runSession()
    case "transcribe": try runTranscribe()
    case "calendar": runCalendar()
    case "speech": runSpeech()
    case "permission": runPermission()
    case "holdmic": try runHoldMic()
    case "mix": try runMix()
    case "app": runApp(arguments.count > 2 ? arguments[2] : "")
    case "-h", "--help", "help":
        print("""
        tapspike <command> [options]

          list                    enumerate Core Audio process objects and who is making sound
          plist                   verify the privacy usage strings survived the build
          record                  capture and run the non-zero sample check (Gate 1)
          watch                   log Teams join/leave transitions (Gate 2)
                                    --bundle-id / --seconds / --start-debounce / --stop-debounce
          session                 run a full RecordingSession incl. meta.json (Gates 3-4)
          calendar                what EventKit can actually see (--days N)
          mix <dir>               combine a recording's tracks into one file (--keep-sources)
          holdmic                 hold then release the mic while staying alive (--seconds --idle)
          transcribe <dir>        transcribe a recording (--model automatic|longForm|dictation, --locale)
          permission              verify system audio capture by playing and hearing a tone
          speech                  compare the two on-device speech models and their locales
                                    --install <locale> [--model longForm|dictation] to pre-download
          app start|stop|settings|library|calendar
                                  drive the running app

        session options:
          --seconds <n>           capture duration (default 10)
          --out <dir>             recordings root (default ./build/session-test)
          --bundle-id <id>        target prefix (default Microsoft Teams)
          --simulate-sleep        force a segment rebuild halfway through

        record options:
          --seconds <n>           capture duration (default 10)
          --out <dir>             output directory (default ./build/spike)
          --bundle-id <id>        target a different app (default Microsoft Teams)
          --pid <n>               target a specific pid
          --global                global tap excluding self (the §6.2 fallback)
          --no-mic                skip microphone capture
        """)
    default:
        print("unknown command '\(command)' — try 'tapspike help'")
        exit(2)
    }
} catch {
    print("✗ \(error.localizedDescription)")
    exit(1)
}
