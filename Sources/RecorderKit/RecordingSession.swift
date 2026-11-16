import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// One recording in progress: a directory, a microphone stream, a system stream, and the
/// `meta.json` that describes them.
///
/// Capture is split into *segments*. Sleep, a Teams or Zoom restart, or the 4-hour hard stop tear the
/// tap down and open a new numbered file rather than trying to splice audio back together —
/// gapless recovery across sleep is an explicit non-goal (plan.md §4, §9.4).
public final class RecordingSession: @unchecked Sendable {
    private static let log = Logger(subsystem: loggingSubsystem, category: "Session")

    public let directory: URL
    public let startedAt: Date
    public private(set) var metadata: RecordingMetadata

    private let store: RecordingStore
    private let bundlePrefixes: [String]
    /// The family actually tapped in the current segment — narrower than `bundlePrefixes` when
    /// more than one meeting app is running. See `MeetingApp.callFamily(of:within:)`.
    private var tappedPrefixes: [String]
    /// False for an in-person meeting: only the microphone is captured, there is no far end to
    /// tap, and nothing should warn about a silent system stream.
    public let capturesSystemAudio: Bool
    private let mic: MicCapture
    private let ownsMic: Bool

    private var tap: ProcessTap?
    private var systemWriter: AudioFileWriter?
    private var micWriter: AudioFileWriter?
    private var segment = 0

    /// Fires when a stream has been silent for the whole check window, mid-recording. Not at
    /// the end — waiting until the meeting is over to report "no audio" is useless (plan.md §9.4).
    public var onSilentStream: (@Sendable (TrackMetadata.Source) -> Void)?

    private var silentWindows: [TrackMetadata.Source: Int] = [:]
    /// How long a stream must be *continuously* silent before it is reported, in seconds.
    ///
    /// The counter ticks once per `sampleLevels()` call and the coordinator samples at 1 Hz, so
    /// windows are seconds. This is a balance: too short and an ordinary pause in the
    /// conversation — nobody talking, everyone muted between agenda items — reads as a dead
    /// capture and cries wolf; too long and a genuinely broken stream goes unreported well into
    /// the meeting. 15 s rides out a normal lull while still catching a failure early.
    public static let silentWindowsBeforeAlert = 15

    public init(
        meeting: MeetingInfo,
        trigger: RecordingMetadata.Trigger,
        store: RecordingStore,
        bundlePrefixes: [String],
        mic: MicCapture?,
        capturesSystemAudio: Bool = true,
        startedAt: Date = Date()
    ) throws {
        try store.checkDiskSpace()

        self.store = store
        self.bundlePrefixes = bundlePrefixes
        self.tappedPrefixes = bundlePrefixes
        self.capturesSystemAudio = capturesSystemAudio
        self.startedAt = startedAt
        self.directory = try store.makeDirectory(for: meeting, at: startedAt)
        self.metadata = RecordingMetadata(meeting: meeting, actualStart: startedAt, trigger: trigger)
        if !capturesSystemAudio { metadata.notes.append("In-person meeting: microphone only, no system audio captured.") }
        if let mic {
            self.mic = mic
            self.ownsMic = false
        } else {
            self.mic = MicCapture()
            self.ownsMic = true
        }

        // Written before any audio exists, so a crash mid-meeting still leaves identifiable
        // audio rather than an anonymous directory (plan.md §9.2).
        store.writeMetadata(metadata, to: directory)
    }

    // MARK: - Segments

    /// Opens the next capture segment. `reason` is nil for the first one.
    public func startSegment(reason: String? = nil) throws {
        closeSegment()
        segment += 1
        if let reason {
            let note = "Segment \(segment) started: \(reason)"
            metadata.notes.append(note)
            Self.log.notice("\(note, privacy: .public)")
        }

        // Ordering rule (plan.md §6.3): the microphone session must be running before the
        // aggregate device is created, or a Bluetooth A2DP→HFP switch happens underneath the
        // aggregate and the mic channel fails silently.
        if !mic.isRunning {
            try? mic.start()
        }
        if let micFormat = mic.format {
            let writer = try AudioFileWriter(
                url: try originalsURL(for: .microphone),
                inputFormat: micFormat, channels: 1, bitRate: 96_000)
            mic.setHandler { [writer] buffer in writer.append(buffer) }
            micWriter = writer
        } else {
            metadata.notes.append("Microphone delivered no audio format; segment \(segment) has no mic track.")
        }

        guard capturesSystemAudio else {
            Self.log.info("segment \(self.segment) capturing microphone only")
            silentWindows = [:]
            return
        }

        let (targets, familyPrefixes) = ProcessResolver.callTargets(matchingPrefixes: bundlePrefixes)
        guard !targets.isEmpty else { throw RecorderError.meetingAppNotRunning }
        tappedPrefixes = familyPrefixes
        if let app = ProcessResolver.appUsingInput(targets) ?? Self.soleApp(of: familyPrefixes) {
            if metadata.app == nil {
                metadata.app = app.name
            } else if metadata.app != app.name {
                metadata.notes.append("Segment \(segment) captured \(app.name), not \(metadata.app ?? "—").")
            }
        }
        Self.log.notice("segment \(self.segment) tapping \(targets.count) process(es): \(familyPrefixes.joined(separator: ", "), privacy: .public)")

        let tap: ProcessTap
        do {
            tap = try ProcessTap(scope: .processes(targets), restoreBundleIDs: familyPrefixes)
        } catch {
            // §6.2 fallback: if the process-scoped tap will not build, tap everything except
            // ourselves. Noisier, but a recording with the wrong neighbours on it beats none.
            Self.log.warning("process-scoped tap failed (\(error.localizedDescription, privacy: .public)); falling back to global tap")
            metadata.notes.append("Process-scoped tap unavailable; used a global tap excluding this app.")
            let ourObject = try? ProcessResolver.processObject(forPID: getpid())
            tap = try ProcessTap(scope: .globalExcluding(ourObject.map { [$0] } ?? []), mono: true)
        }

        let writer = try AudioFileWriter(
            url: try originalsURL(for: .system),
            inputFormat: tap.format,
            channels: min(2, tap.format.channelCount),
            bitRate: 128_000)
        try tap.start { [writer] buffer, _ in writer.append(buffer) }

        self.tap = tap
        self.systemWriter = writer
        silentWindows = [:]
        Self.log.info("segment \(self.segment) capturing — tap format \(tap.format, privacy: .public)")
    }

    /// Path for a raw capture, creating the originals subfolder on demand.
    private func originalsURL(for source: TrackMetadata.Source) throws -> URL {
        let folder = directory.appendingPathComponent(RecordingStore.originalsFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(
            RecordingStore.trackFilename(source: source, segment: segment))
    }

    private func closeSegment() {
        tap?.stop()
        tap?.invalidate()
        tap = nil
        mic.setHandler(nil)
        if let systemWriter { record(systemWriter, source: .system) }
        if let micWriter { record(micWriter, source: .microphone) }
        systemWriter?.close()
        micWriter?.close()
        systemWriter = nil
        micWriter = nil
    }

    private func record(_ writer: AudioFileWriter, source: TrackMetadata.Source) {
        let rms = writer.meter.rms
        metadata.tracks.append(TrackMetadata(
            file: RecordingStore.trackRelativePath(source: source, segment: segment),
            source: source,
            rmsOK: rms >= LevelMeter.silenceThreshold,
            rms: rms,
            segment: segment,
            startOffset: writer.firstBufferAt.map { $0.timeIntervalSince(startedAt) },
            peak: writer.meter.peakAmplitude))
        if writer.didFail {
            metadata.notes.append("Write errors occurred on \(writer.url.lastPathComponent).")
        }
    }

    // MARK: - Live state

    public struct Levels: Sendable {
        public var system: Float
        public var microphone: Float
    }

    /// Consumes the current level window. Called once a second by the coordinator, which is
    /// what drives both the menu-bar meter and the silence watchdog.
    public func sampleLevels() -> Levels {
        let system = systemWriter?.meter.consumeWindowRMS() ?? 0
        let microphone = micWriter?.meter.consumeWindowRMS() ?? 0

        check(source: .system, level: system, hasWriter: systemWriter != nil)
        check(source: .microphone, level: microphone, hasWriter: micWriter != nil)

        return Levels(system: system, microphone: microphone)
    }

    private func check(source: TrackMetadata.Source, level: Float, hasWriter: Bool) {
        guard hasWriter else { return }
        guard source != .system || capturesSystemAudio else { return }
        if level >= LevelMeter.silenceThreshold {
            silentWindows[source] = 0
            return
        }
        let count = (silentWindows[source] ?? 0) + 1
        silentWindows[source] = count
        if count == Self.silentWindowsBeforeAlert {
            let note = "\(source.rawValue) stream was silent for \(count)s during the call."
            metadata.notes.append(note)
            Self.log.error("\(note, privacy: .public)")
            onSilentStream?(source)
        }
    }

    public var elapsed: TimeInterval { Date().timeIntervalSince(startedAt) }

    public func addNote(_ note: String) {
        metadata.notes.append(note)
        Self.log.notice("\(note, privacy: .public)")
    }

    /// Whether the tap is still attached to a live process of the app being recorded. A restart
    /// invalidates the process object and the tap silently stops delivering. Checked against the
    /// tapped family only: Teams still running says nothing about a Zoom call's tap.
    public func targetsAreAlive() -> Bool {
        !ProcessResolver.processObjects(matchingPrefixes: tappedPrefixes).isEmpty
    }

    /// The supported app these prefixes belong to, when they all belong to exactly one.
    private static func soleApp(of prefixes: [String]) -> MeetingApp? {
        let apps = Set(prefixes.compactMap(MeetingApp.app(forBundleID:)))
        return apps.count == 1 ? apps.first : nil
    }

    // MARK: - Finishing

    @discardableResult
    public func finish(at date: Date = Date()) -> RecordingMetadata {
        closeSegment()
        if ownsMic { mic.stop() }
        metadata.actualEnd = date
        // Capture is done, but mixing and transcription are not — the coordinator marks this
        // complete when the post-processing finishes.
        metadata.status = .processing
        store.writeMetadata(metadata, to: directory)
        Self.log.info("finished \(self.directory.lastPathComponent, privacy: .public) — \(self.metadata.tracks.count) track(s)")
        return metadata
    }

    public func flushMetadata() {
        store.writeMetadata(metadata, to: directory)
    }
}
