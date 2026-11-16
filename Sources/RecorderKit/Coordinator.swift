import AppKit
import AVFoundation
import Foundation
import OSLog

/// The state machine. The only thing in the app that starts or stops capture (plan.md §5).
///
///     IDLE ──▶ ARMED ──▶ RECORDING ──▶ FINALIZING ──▶ IDLE
///                             │
///                             └── stopped by user ──▶ IDLE
///
/// `ProcessMonitor` decides *when*; `CalendarService` decides what it is *called*;
/// `RecordingSession` does the capture. This class owns the policy that connects them and the
/// edge cases in §9.4 — sleep, device changes, back-to-back meetings, runaway recordings.
@MainActor
@Observable
public final class Coordinator {
    public enum State: String, Sendable {
        case idle
        case armed
        case recording
        case finalizing
    }

    private nonisolated static let log = Logger(subsystem: loggingSubsystem, category: "Coordinator")

    /// Every supported meeting app — see `MeetingApp`.
    public nonisolated static let defaultBundlePrefixes = MeetingApp.allBundlePrefixes

    /// What is actually being watched and tapped — Teams and Zoom unless overridden for testing.
    public var targetBundlePrefixes: [String] { settings.targetBundlePrefixes }

    public private(set) var state: State = .idle
    public private(set) var currentTitle: String?
    public private(set) var startedAt: Date?
    /// Folder of the recording currently being captured, so the library can tell which of its
    /// rows is the live one.
    public private(set) var currentDirectory: URL?
    public private(set) var elapsed: TimeInterval = 0
    public private(set) var systemLevel: Float = 0
    public private(set) var micLevel: Float = 0
    public private(set) var lastError: String?
    public private(set) var meetingAppIsRunning = false
    /// The app whose call is armed or being recorded, for the status line. Nil when idle, for an
    /// in-person recording, or when nothing was using the microphone at start.
    public private(set) var activeApp: MeetingApp?
    /// Recordings whose capture has finished but whose mixing or transcription is still running.
    /// Observable so the library reflects it without polling.
    public private(set) var processing: Set<URL> = []

    public var store: RecordingStore

    private let settings: RecorderSettings
    private let calendar = CalendarService()
    private let monitor: ProcessMonitor
    private var mic = MicCapture()
    private var session: RecordingSession?
    private var ticker: Timer?
    private var didWarnSilentThisSession = Set<TrackMetadata.Source>()
    private var sleepPending = false
    private var currentEventID: String?

    /// Calendar events already noted as "moved on to" during this recording, so an overrun adds
    /// one note per meeting rather than one per second.
    private var notedCalendarMoves: Set<String> = []
    /// True between the start request and the tap actually running — capture start is async
    /// now, so a second request must not slip in behind it.
    private var isStartingCapture = false
    /// Last moment a meeting app was seen using an input device during the current recording, and
    /// whether it ever was. Drives the stop watchdog below.
    private var lastAppInputAt: Date?
    private var sawAppInputWhileRecording = false
    /// Notes are appended to `meta.json`, so a per-tick condition has to be latched or it writes
    /// the same line once a second for the length of the meeting.
    private var didNoteTargetsGone = false

    public init(settings: RecorderSettings = .shared) {
        self.settings = settings
        self.store = RecordingStore(root: settings.recordingsRoot)
        AlertCenter.shared.logDirectory = settings.recordingsRoot
        self.monitor = ProcessMonitor(bundlePrefixes: settings.targetBundlePrefixes)
        monitor.startDebounce = settings.startDebounce
        monitor.stopDebounce = settings.stopDebounce
    }

    // MARK: - Lifecycle

    public func start() {
        monitor.onStateChange = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        monitor.start()
        observeSystemEvents()
        observeCommands()

        resumeUnfinishedProcessing()

        ticker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Notifications.shared.actionHandler = { [weak self] action, userInfo in
            Task { @MainActor in self?.handle(action, userInfo: userInfo) }
        }
    }

    public func shutdown() {
        ticker?.invalidate()
        ticker = nil
        monitor.stop()
        // Synchronous on purpose: the process is about to exit, and the files have to be closed
        // before it does.
        if let session {
            self.session = nil
            session.addNote("Stopped: app is quitting")
            session.finish()
        }
        mic.stop()
    }

    /// Local control hook, so the app itself can be smoke-tested without a mouse.
    ///
    /// Session-scoped `DistributedNotificationCenter`, no network surface. It exposes exactly
    /// what the menu already exposes — manual start and manual stop.
    public enum Command {
        public static let start = Notification.Name("com.raywong.MeetingRecorder.startRecording")
        public static let stop = Notification.Name("com.raywong.MeetingRecorder.stopRecording")
        public static let startInPerson = Notification.Name("com.raywong.MeetingRecorder.startInPerson")
        /// Opens the name prompt, exactly as the menu item does.
        public static let askInPerson = Notification.Name("com.raywong.MeetingRecorder.askInPerson")
        public static let openSettings = Notification.Name("com.raywong.MeetingRecorder.openSettings")
        public static let openLibrary = Notification.Name("com.raywong.MeetingRecorder.openLibrary")
        /// Dumps what EventKit can see to the unified log — the check for whether the work
        /// calendar is actually reachable from this Mac.
        public static let dumpCalendar = Notification.Name("com.raywong.MeetingRecorder.dumpCalendar")
    }

    private func observeCommands() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Command.start, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.startByUser() }
        }
        center.addObserver(forName: Command.stop, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopByUser() }
        }
        center.addObserver(forName: Command.startInPerson, object: nil, queue: .main) { [weak self] note in
            let title = note.userInfo?["title"] as? String
            Task { @MainActor in self?.startInPersonByUser(title: title) }
        }
        center.addObserver(forName: Command.dumpCalendar, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.dumpCalendar() }
        }
    }

    // MARK: - Monitor events

    private func handle(_ event: ProcessMonitor.Event) {
        switch event {
        case .targetAppeared:
            meetingAppIsRunning = true
        case .targetDisappeared:
            meetingAppIsRunning = false
        case .armed:
            guard settings.isAutoRecordActive, session == nil else { return }
            state = .armed
            activeApp = monitor.appUsingInput()
            // Bring the mic up now rather than at .callStarted: it has to be running before
            // the aggregate device is created (plan.md §6.3), and the start debounce is
            // exactly the spare few seconds in which to do it. Off the main actor — opening a
            // Bluetooth input can take seconds while the profile renegotiates.
            let mic = self.mic
            if !mic.isRunning {
                Task.detached(priority: .userInitiated) { try? mic.start(timeout: 1.0) }
            }
        case .aborted:
            // Only unwind if nothing is actually being captured — `.armed` also covers the
            // window while a capture is starting up.
            if state == .armed, session == nil {
                state = .idle
                activeApp = nil
                releaseMicIfIdle()
            }
        case .callStarted:
            guard settings.isAutoRecordActive else {
                Self.log.notice("call started but auto-record is paused")
                state = .idle
                return
            }
            startRecording(trigger: .auto)
        case .finalizing:
            if session != nil { state = .finalizing }
        case .callEnded:
            if session != nil {
                stopRecording(reason: "call ended")
            } else {
                releaseMicIfIdle()
            }
        }
    }

    private func dumpCalendar() {
        let status = CalendarService.authorizationStatus
        Self.log.notice("calendar authorization: \(String(describing: status), privacy: .public)")
        let calendars = calendar.calendarInventory()
        Self.log.notice("calendars visible: \(calendars.count)")
        for entry in calendars {
            Self.log.notice("  calendar: \(entry.title, privacy: .public)  [source: \(entry.source, privacy: .public)]")
        }
        let now = Date()
        let events = calendar.rawEvents(from: now.addingTimeInterval(-7 * 86400), to: now.addingTimeInterval(7 * 86400))
        let linkedCount = events.filter { $0.app != nil }.count
        Self.log.notice("events in ±7 days: \(events.count), with a Teams or Zoom join link: \(linkedCount)")

        // What would actually be written into meta.json for the next few online meetings.
        for meeting in calendar.meetings(from: now, to: now.addingTimeInterval(7 * 86400)).prefix(3) {
            Self.log.notice("  would record as \"\(meeting.title, privacy: .public)\" — organizer: \(meeting.organizer ?? "—", privacy: .public); attendees: \(meeting.attendees.joined(separator: "; "), privacy: .public)")
        }
        for event in events.sorted(by: { $0.start < $1.start }).prefix(15) {
            Self.log.notice("  \(event.app?.name.prefix(1) ?? "-", privacy: .public) \(event.start, privacy: .public) \(event.title, privacy: .public) [\(event.calendar, privacy: .public)]")
        }
    }

    // MARK: - Recording control

    /// - Parameters:
    ///   - capturesSystemAudio: false for an in-person meeting — microphone only.
    ///   - title: a name supplied by the user, which wins over anything the calendar says.
    public func startRecording(
        trigger: RecordingMetadata.Trigger,
        capturesSystemAudio: Bool = true,
        title: String? = nil
    ) {
        guard session == nil, !isStartingCapture else { return }

        // The calendar names automatic recordings only. Pressing record by hand is an explicit
        // "this one, now" — it may well be nothing to do with whatever the calendar says is
        // happening, so borrowing that meeting's name would mislabel it.
        let app = capturesSystemAudio ? monitor.appUsingInput() : nil
        let meeting: MeetingInfo
        if let title, !title.isEmpty {
            meeting = .named(title)
        } else {
            // The app in the call picks between overlapping Teams and Zoom events.
            meeting = trigger == .auto ? calendar.meeting(for: app) : .adHoc
        }
        let session: RecordingSession
        do {
            session = try RecordingSession(
                meeting: meeting,
                trigger: trigger,
                store: store,
                bundlePrefixes: settings.targetBundlePrefixes,
                mic: mic,
                capturesSystemAudio: capturesSystemAudio)
        } catch {
            fail("Could not start recording: \(error.localizedDescription)")
            return
        }
        session.onSilentStream = { [weak self] source in
            Task { @MainActor in self?.warnSilent(source) }
        }

        self.session = session
        self.activeApp = app
        self.currentDirectory = session.directory
        self.currentEventID = meeting.eventIdentifier
        isStartingCapture = true
        state = .armed
        startedAt = session.startedAt
        currentTitle = meeting.title
        lastError = nil
        didWarnSilentThisSession = []
        lastAppInputAt = Date()
        sawAppInputWhileRecording = capturesSystemAudio && monitor.inputIsActive()
        didNoteTargetsGone = false

        // If the tap has not started shortly, the TCC prompt is sitting unanswered somewhere
        // (`AudioDeviceStart` blocks until it is). Say so, rather than sitting in ARMED with a
        // mic track quietly recording and no far-end audio at all.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.isStartingCapture, self.session === session else { return }
            AlertCenter.shared.post(
                .critical,
                title: "Waiting for permission to record system audio",
                body: "Answer the macOS prompt, or grant Meeting Recorder access under Privacy & Security ▸ Audio Recording. Your microphone is recording; the far end is not.",
                category: .silent)
        }

        // Off the main actor, and this is not a micro-optimisation.
        //
        // `AudioDeviceStart` is where the TCC prompt fires (plan.md §6.4), and it blocks the
        // calling thread until that prompt is answered — indefinitely, if it is never answered.
        // Called on the main actor it freezes the whole app: the menu stops responding, the
        // ticker stops, and a stop request cannot be processed, so the recording cannot even be
        // cancelled. Bringing the mic session up can block for seconds too.
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try session.startSegment()
                await self?.captureDidStart(session)
            } catch {
                await self?.captureDidFail(session, reason: error.localizedDescription)
            }
        }
    }

    private func markProcessingFinished(_ directory: URL) {
        processing.remove(directory)
    }

    private func resumeAfterSleepFailed(_ reason: String) {
        fail("Could not resume after sleep: \(reason)")
        stopRecording(reason: "capture could not be rebuilt after sleep")
    }

    private func captureDidStart(_ session: RecordingSession) {
        guard session === self.session else { return }
        isStartingCapture = false
        state = .recording
        AlertCenter.shared.post(
            .info, title: "Recording", body: session.metadata.title,
            category: .started, userInfo: ["directory": session.directory.path])
        Self.log.notice("recording started — \(session.metadata.title, privacy: .public)")
    }

    private func captureDidFail(_ session: RecordingSession, reason: String) {
        guard session === self.session else { return }
        isStartingCapture = false
        self.session = nil
        activeApp = nil
        currentDirectory = nil
        currentEventID = nil
        notedCalendarMoves = []
        startedAt = nil
        currentTitle = nil
        session.addNote("Capture failed to start: \(reason)")
        session.finish()
        fail("Could not start recording: \(reason)")
    }

    public func stopRecording(reason: String) {
        guard let session else { return }
        self.session = nil
        self.currentDirectory = nil
        self.currentEventID = nil
        self.notedCalendarMoves = []
        isStartingCapture = false
        state = .finalizing
        systemLevel = 0
        micLevel = 0

        // `AudioDeviceStop` and closing the aggregate can block as well — same reasoning.
        Task.detached(priority: .userInitiated) { [weak self] in
            session.addNote("Stopped: \(reason)")
            let metadata = session.finish()
            await self?.captureDidStop(session, metadata: metadata, reason: reason)
        }
    }

    private func captureDidStop(_ session: RecordingSession, metadata: RecordingMetadata, reason: String) {
        if self.session == nil {
            state = .idle
            activeApp = nil
            startedAt = nil
            currentTitle = nil
            releaseMicIfIdle()
        }

        let duration = Self.format(metadata.duration ?? 0)
        let size = ByteCountFormatter().string(
            fromByteCount: Recording(directory: session.directory, metadata: metadata).totalSize)
        AlertCenter.shared.post(
            metadata.hasSilentTrack ? .warning : .info,
            title: metadata.hasSilentTrack ? "Saved — with a silent track" : "Saved",
            body: "\(metadata.title) — \(duration), \(size)",
            category: .stopped,
            userInfo: ["directory": session.directory.path])
        Self.log.notice("recording stopped (\(reason, privacy: .public)) — \(duration, privacy: .public)")

        finishInBackground(Recording(directory: session.directory, metadata: metadata))
    }

    /// Post-processing after `FINALIZING`: mix the two tracks into one file if that is what the
    /// output mode asks for, then transcribe. Never on the capture path.
    ///
    /// The recording is marked `processing` in `meta.json` for the whole of this, and listed in
    /// `processing` here, so the library can say what is happening instead of briefly showing a
    /// recording with no combined file and no transcript for no visible reason.
    private func finishInBackground(_ recording: Recording) {
        let mode = settings.outputMode
        let transcribe = settings.transcriptionEnabled
        let locale = settings.transcriptionLocale
        let modelRawValue = settings.transcriptionModelRawValue
        let store = self.store
        let directory = recording.directory

        processing.insert(directory)
        Task.detached(priority: .background) { [weak self] in
            var recording = recording
            if mode != .separate {
                let metadata = await RecordingMixer.mixSegments(
                    of: recording, removeSources: mode == .mixed)
                store.writeMetadata(metadata, to: directory)
                recording = Recording(directory: directory, metadata: metadata)
            }
            if transcribe, #available(macOS 26.0, *) {
                await Self.transcribe(recording, locale: locale, modelRawValue: modelRawValue)
            }

            var finished = recording.metadata
            finished.status = .complete
            store.writeMetadata(finished, to: directory)
            await self?.markProcessingFinished(directory)
        }
    }

    /// Picks up anything left mid-processing by a quit or a crash.
    ///
    /// Without this a recording interrupted after capture but before mixing would sit in the
    /// library saying "Processing…" forever, with nothing ever coming to finish it.
    private func resumeUnfinishedProcessing() {
        let unfinished = store.allRecordings().filter { !$0.metadata.isFinished }
        guard !unfinished.isEmpty else { return }
        Self.log.notice("resuming post-processing for \(unfinished.count) unfinished recording(s)")
        for recording in unfinished {
            var metadata = recording.metadata
            if metadata.actualEnd == nil {
                // Capture never closed cleanly — nothing to resume, just stop claiming it is live.
                metadata.actualEnd = metadata.actualStart
                metadata.notes.append("Recording was interrupted before it finished.")
                store.writeMetadata(metadata, to: recording.directory)
            }
            finishInBackground(Recording(directory: recording.directory, metadata: metadata))
        }
    }

    /// Manual stop from the menu bar. The most important control in the UI: there will be
    /// meetings you want to stop recording partway through (plan.md §10).
    public func stopByUser() { stopRecording(reason: "stopped by user") }

    public func startByUser() { startRecording(trigger: .manual) }

    /// An in-person meeting: microphone only, no tap, no far-end silence warnings.
    public func startInPersonByUser(title: String? = nil) {
        startRecording(trigger: .manual, capturesSystemAudio: false, title: title)
    }

    /// Renames a finished recording from the library.
    public func rename(_ recording: Recording, to title: String) -> Recording {
        store.rename(recording, to: title)
    }

    // MARK: - Per-second work

    private func tick() {
        guard let session else {
            elapsed = 0
            return
        }
        elapsed = session.elapsed
        let levels = session.sampleLevels()
        systemLevel = levels.system
        micLevel = levels.microphone

        // None of the meeting-app signals apply to an in-person recording: there is no tap, and
        // whatever Teams or Zoom happens to be doing is irrelevant to a meeting in the room.
        guard session.capturesSystemAudio else { return }

        // Stop when the meeting app releases the microphone, independent of the monitor's own state
        // machine. `.callEnded` only fires if the machine had entered `isInCall`, which it never
        // does for a recording started by hand, or one already running when the app launched —
        // so relying on it alone leaves recordings that never end.
        if monitor.inputIsActive() {
            lastAppInputAt = Date()
            sawAppInputWhileRecording = true
            // A recording started by hand before joining learns its app here.
            if activeApp == nil { activeApp = monitor.appUsingInput() }
        } else if sawAppInputWhileRecording,
                  let last = lastAppInputAt,
                  Date().timeIntervalSince(last) >= settings.stopDebounce {
            stopRecording(reason: "\(activeApp?.name ?? "meeting app") stopped using the microphone")
            return
        }

        // Runaway recording: hard stop at the configured limit, then start a fresh recording
        // if audio is still live (plan.md §9.4).
        if elapsed >= settings.maxRecordingHours * 3600 {
            stopRecording(reason: "hard stop at \(Int(settings.maxRecordingHours))h")
            if monitor.isInCall { startRecording(trigger: .auto) }
            return
        }

        // The calendar never stops a recording. A recording ends when the app releases the audio
        // device — i.e. when you actually leave the call — and nothing else.
        //
        // This reverses plan.md §9.4's "never merge two events into one file". That rule assumed
        // meeting audio runs continuously across back-to-back meetings, so only the calendar could
        // tell them apart. In practice moving between calls *does* release the audio device, so the
        // stop debounce above already splits genuine transitions. What the calendar rule actually
        // caught was meetings that **overran**: a 10:00-11:00 call still going at 11:00 was cut in
        // half and its tail labelled with the next meeting on the calendar, which is wrong twice
        // over. Continuous audio now means one recording, named for the meeting you joined.
        //
        // The calendar moving on is still worth recording, because it is the thing that makes a
        // long recording explicable a year later. Latched per event, so a 90-minute overrun does
        // not accumulate 90 identical notes.
        if state == .recording, let currentEventID, session.metadata.trigger == .auto {
            let next = calendar.meeting(for: activeApp)
            if let movedTo = next.eventIdentifier,
               movedTo != currentEventID,
               !notedCalendarMoves.contains(movedTo) {
                notedCalendarMoves.insert(movedTo)
                let title = next.title
                session.addNote("Calendar moved on to \u{201C}\(title)\u{201D} while this call was "
                                + "still running; kept recording as one meeting.")
            }
        }

        // An app restart invalidates the process object and the tap goes quiet with no error.
        // Latched: this is a per-tick condition and the note is permanent.
        if state == .recording, !session.targetsAreAlive(), !didNoteTargetsGone {
            didNoteTargetsGone = true
            session.addNote("\(activeApp?.name ?? "Meeting app") process disappeared mid-recording.")
        }
    }

    /// Closes the microphone session once nothing is recording.
    ///
    /// The capture session is shared across recordings and brought up early, at `ARMED`, so the
    /// Bluetooth profile switch happens before the aggregate device exists (plan.md §6.3).
    /// Nothing was closing it afterwards, so the orange microphone indicator stayed lit and the
    /// app held the input device open indefinitely — until it was quit.
    private func releaseMicIfIdle() {
        guard session == nil, !isStartingCapture, mic.isRunning else { return }
        let mic = self.mic
        Task.detached(priority: .utility) { mic.stop() }
        Self.log.notice("microphone released")
    }

    private func warnSilent(_ source: TrackMetadata.Source) {
        guard !didWarnSilentThisSession.contains(source) else { return }
        didWarnSilentThisSession.insert(source)
        let label = source == .microphone ? "microphone" : "system audio"
        AlertCenter.shared.post(
            .critical,
            title: "No audio on \(label)",
            body: "Check Privacy & Security permissions — the recording is continuing, but that track is silent.",
            category: .silent)
    }

    private func fail(_ message: String) {
        lastError = message
        state = .idle
        Self.log.error("\(message, privacy: .public)")
        AlertCenter.shared.post(.critical, title: "Recording failed", body: message, category: .failure)
    }

    // MARK: - System events (plan.md §9.4)

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter

        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWillSleep() }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleDidWake() }
        }
    }

    private func handleWillSleep() {
        guard let session, state == .recording else { return }
        sleepPending = true
        session.addNote("System went to sleep; capture torn down.")
    }

    /// The aggregate device does not reliably survive sleep, so it is rebuilt into a new
    /// numbered file. No attempt is made at gapless recovery — that is an explicit non-goal.
    private func handleDidWake() {
        guard sleepPending, let session, state == .recording else {
            sleepPending = false
            return
        }
        sleepPending = false
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try session.startSegment(reason: "resumed after system sleep")
            } catch {
                await self?.resumeAfterSleepFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Notification actions

    private func handle(_ action: Notifications.Action, userInfo: [String: String]) {
        switch action {
        case .stop:
            stopByUser()
        case .open, .reveal:
            guard let path = userInfo["directory"] else { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        case .openSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .openLog:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Utilities/Console.app"))
        }
    }

    // MARK: - Transcription (plan.md §14)

    @available(macOS 26.0, *)
    private nonisolated static func transcribe(
        _ recording: Recording, locale: Locale, modelRawValue: String
    ) async {
        do {
            let url = try await TranscriptionService.transcribe(
                recording,
                locale: locale,
                model: TranscriptionService.Model(rawValue: modelRawValue) ?? .automatic)
            log.info("transcript written to \(url.lastPathComponent, privacy: .public)")
        } catch {
            // A failed transcript is a missing convenience, not a lost recording — log it and
            // stay quiet rather than firing a notification the audio does not warrant.
            log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Daily health check (plan.md §13)

    /// Compares yesterday's qualifying calendar events against recordings on disk and reports
    /// any that produced nothing. This is what catches a detector that has quietly stopped
    /// working — the failure mode that otherwise goes unnoticed for weeks (plan.md §15.6).
    public func runDailyHealthCheckIfNeeded(now: Date = Date()) {
        var calendarInstance = Calendar(identifier: .gregorian)
        calendarInstance.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        let today = RecordingStore.timestamp(now).prefix(10)
        guard settings.lastHealthCheckDay != String(today) else { return }
        settings.lastHealthCheckDay = String(today)

        let startOfToday = calendarInstance.startOfDay(for: now)
        guard let startOfYesterday = calendarInstance.date(byAdding: .day, value: -1, to: startOfToday) else { return }

        let expected = calendar.meetings(from: startOfYesterday, to: startOfToday)
        guard !expected.isEmpty else { return }

        let recorded = Set(store.allRecordings().compactMap(\.metadata.eventID))
        let missed = expected.filter { info in
            guard let id = info.eventIdentifier else { return false }
            return !recorded.contains(id)
        }
        guard !missed.isEmpty else { return }

        let titles = missed.prefix(3).map(\.title).joined(separator: ", ")
        AlertCenter.shared.post(
            .warning,
            title: "\(missed.count) meeting\(missed.count == 1 ? "" : "s") yesterday had no recording",
            body: titles,
            category: .healthCheck)
        Self.log.error("daily health check: \(missed.count) unrecorded meeting(s) yesterday")
    }

    // MARK: - Helpers

    /// `nonisolated` so the library window, the transcript renderer, and the CLI can all
    /// format a duration without hopping to the main actor.
    public nonisolated static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
