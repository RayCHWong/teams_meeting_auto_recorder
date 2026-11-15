import CoreAudio
import Foundation
import OSLog

/// Watches the supported meeting apps (Teams, Zoom) and reports when a call actually starts
/// and ends.
///
/// The signal is `kAudioProcessPropertyIsRunningInput` — the app pulling from an input device.
/// All watched apps are one pool: input on any of them is a call. Which app it is matters only
/// for naming and for what gets tapped, and that is decided at capture time
/// (`ProcessResolver.callTargets`).
/// This beats a calendar window outright: it handles joining late, leaving early, skipped
/// meetings, and ad-hoc calls that were never on the calendar (plan.md §3, §7).
///
/// Two details the plan could not know until the HAL was actually enumerated:
///
///   * There is no process object for `com.microsoft.teams2`. Teams appears only as its
///     children, so the monitor tracks the whole family by bundle-id prefix and treats
///     input on *any* of them as the join signal.
///   * The set of children changes as Teams spawns and reaps helpers, so the family is
///     re-enumerated on every poll rather than resolved once at start-up.
///
/// A HAL property listener provides responsiveness; a 2 s poll provides correctness when the
/// listener does not fire. Silent detector failure is the thing this project cannot afford.
public final class ProcessMonitor: @unchecked Sendable {
    public enum Event: CustomStringConvertible, Sendable {
        case targetAppeared(processCount: Int)
        case targetDisappeared
        case armed                 // input started; start debounce running
        case callStarted
        case finalizing            // input stopped; stop debounce running
        case callEnded
        case aborted               // input stopped before the start debounce elapsed

        public var description: String {
            switch self {
            case .targetAppeared(let count): return "target appeared — \(count) process object(s)"
            case .targetDisappeared: return "target disappeared — no meeting app is running"
            case .armed: return "ARMED (input started, waiting out start debounce)"
            case .callStarted: return "RECORDING (call started)"
            case .finalizing: return "FINALIZING (input stopped, waiting out stop debounce)"
            case .callEnded: return "IDLE (call ended)"
            case .aborted: return "armed → idle (input stopped before debounce elapsed)"
            }
        }
    }

    private static let log = Logger(subsystem: loggingSubsystem, category: "ProcessMonitor")

    /// 3 s to start, 10 s to stop. The stop debounce is the important one: switching headsets or
    /// changing audio device must not end a recording (plan.md §5 specified 20 s; shortened at
    /// the owner's request, since a device swap settles in a second or two).
    public var startDebounce: TimeInterval = 3
    public var stopDebounce: TimeInterval = 10
    public var pollInterval: TimeInterval = 2

    public var onStateChange: (@Sendable (Event) -> Void)?

    public private(set) var isInCall = false

    private let bundlePrefixes: [String]
    private let queue = DispatchQueue(label: "com.raywong.meetingrecorder.monitor")
    private var timer: DispatchSourceTimer?
    private var trackedObjects: [AudioObjectID] = []
    private var listeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var inputStartedAt: Date?
    private var inputStoppedAt: Date?

    public init(bundlePrefixes: [String]) {
        self.bundlePrefixes = bundlePrefixes
    }

    /// Whether any watched process is pulling from an input device *right now*.
    ///
    /// Deliberately separate from `isInCall`: that is the debounced state machine, and a
    /// recording started manually — or one running when the machine drifts — still needs a
    /// truthful answer to "is a meeting app using the microphone?"
    public func inputIsActive() -> Bool {
        queue.sync { ProcessResolver.anyRunningInput(trackedObjects) }
    }

    /// Which supported app is using the microphone right now, if any.
    public func appUsingInput() -> MeetingApp? {
        queue.sync { ProcessResolver.appUsingInput(trackedObjects) }
    }

    /// The process objects currently being watched — this is also what gets tapped, so the
    /// tap covers whichever helper actually owns the call audio.
    public func currentTargets() -> [AudioObjectID] {
        queue.sync { trackedObjects }
    }

    public func start() {
        queue.async { [self] in
            refreshTargets()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            removeAllListeners()
            trackedObjects = []
            isInCall = false
            inputStartedAt = nil
            inputStoppedAt = nil
        }
    }

    // MARK: - Target tracking

    private func refreshTargets() {
        let found = ProcessResolver.processObjects(matchingPrefixes: bundlePrefixes)
        guard Set(found) != Set(trackedObjects) else { return }

        let wasEmpty = trackedObjects.isEmpty
        removeAllListeners()
        trackedObjects = found
        for object in found { installListener(on: object) }

        if found.isEmpty {
            emit(.targetDisappeared)
            // Every meeting app going away ends any call in progress; there is nothing left to
            // watch and no debounce worth waiting out (plan.md §9.4).
            if isInCall {
                isInCall = false
                inputStoppedAt = nil
                emit(.callEnded)
            }
        } else if wasEmpty {
            emit(.targetAppeared(processCount: found.count))
        } else {
            Self.log.debug("meeting app process family changed — now \(found.count) object(s)")
        }
    }

    private func installListener(on object: AudioObjectID) {
        var address = CA.address(kAudioProcessPropertyIsRunningInput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let monitor = self else { return }
            monitor.queue.async { monitor.tick() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners[object] = block
        }
    }

    private func removeAllListeners() {
        var address = CA.address(kAudioProcessPropertyIsRunningInput)
        for (object, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        listeners.removeAll()
    }

    // MARK: - State machine

    private func tick() {
        refreshTargets()
        guard !trackedObjects.isEmpty else { return }

        let hasInput = ProcessResolver.anyRunningInput(trackedObjects)
        let now = Date()

        if hasInput {
            inputStoppedAt = nil
            if isInCall { return }
            guard let startedAt = inputStartedAt else {
                inputStartedAt = now
                emit(.armed)
                return
            }
            if now.timeIntervalSince(startedAt) >= startDebounce {
                isInCall = true
                inputStartedAt = nil
                emit(.callStarted)
            }
        } else {
            if inputStartedAt != nil, !isInCall {
                inputStartedAt = nil
                emit(.aborted)
                return
            }
            guard isInCall else { return }
            guard let stoppedAt = inputStoppedAt else {
                inputStoppedAt = now
                emit(.finalizing)
                return
            }
            if now.timeIntervalSince(stoppedAt) >= stopDebounce {
                isInCall = false
                inputStoppedAt = nil
                emit(.callEnded)
            }
        }
    }

    private func emit(_ event: Event) {
        // `.notice`, not `.info`: info-level entries are not persisted to disk and age out of
        // the in-memory ring within minutes, so by the time a missed auto-stop is reported the
        // evidence is already gone. These transitions are the whole diagnostic record.
        Self.log.notice("\(event.description, privacy: .public)")
        onStateChange?(event)
    }
}
