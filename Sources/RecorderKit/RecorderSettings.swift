import Foundation
import Observation
import ServiceManagement

/// User-facing configuration, backed by `UserDefaults`.
@Observable
@MainActor
public final class RecorderSettings {
    public static let shared = RecorderSettings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let recordingsRoot = "recordingsRoot"
        static let autoRecordEnabled = "autoRecordEnabled"
        static let pausedUntil = "autoRecordPausedUntil"
        static let notificationsEnabled = "notificationsEnabled"
        static let transcriptionEnabled = "transcriptionEnabled"
        static let maxRecordingHours = "maxRecordingHours"
        static let lastHealthCheckDay = "lastHealthCheckDay"
        static let startDebounce = "startDebounceSeconds"
        static let stopDebounce = "stopDebounceSeconds"
        static let targetBundlePrefixes = "targetBundlePrefixes"
        static let outputMode = "outputMode"
        static let transcriptionModel = "transcriptionModel"
        static let transcriptionLocale = "transcriptionLocale"
    }

    private init() {
        defaults.register(defaults: [
            Key.autoRecordEnabled: true,
            Key.notificationsEnabled: true,
            Key.transcriptionEnabled: false,
            Key.maxRecordingHours: 4.0,
            Key.startDebounce: 3.0,
            Key.stopDebounce: 20.0,
        ])
    }

    /// What ends up in the recording folder once a call is over.
    public enum OutputMode: String, CaseIterable, Sendable {
        /// One combined file. Easiest to play and share; cannot be taken apart again, so
        /// per-speaker transcription attribution is lost.
        case mixed
        /// The two capture tracks, untouched — what `plan.md` §3 specifies.
        case separate
        /// Mixed file plus the two sources. Costs roughly double the disk.
        case both

        public var title: String {
            switch self {
            case .mixed: return "One combined file"
            case .separate: return "Separate mic and far-end tracks"
            case .both: return "Combined file and separate tracks"
            }
        }
    }

    public var outputMode: OutputMode {
        get { OutputMode(rawValue: defaults.string(forKey: Key.outputMode) ?? "") ?? .mixed }
        set { defaults.set(newValue.rawValue, forKey: Key.outputMode) }
    }

    /// Which on-device speech model transcribes recordings.
    public var transcriptionModel: TranscriptionService.Model {
        get {
            TranscriptionService.Model(rawValue: defaults.string(forKey: Key.transcriptionModel) ?? "")
                ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: Key.transcriptionModel) }
    }

    /// Spoken language of the meetings. Defaults to the Mac's own language.
    public var transcriptionLocale: Locale {
        get {
            if let identifier = defaults.string(forKey: Key.transcriptionLocale) {
                return Locale(identifier: identifier)
            }
            return Locale.current
        }
        set { defaults.set(newValue.identifier, forKey: Key.transcriptionLocale) }
    }

    public var recordingsRoot: URL {
        get {
            (defaults.string(forKey: Key.recordingsRoot).map { URL(fileURLWithPath: $0) })
                ?? RecordingStore.defaultRoot
        }
        set { defaults.set(newValue.path, forKey: Key.recordingsRoot) }
    }

    public var autoRecordEnabled: Bool {
        get { defaults.bool(forKey: Key.autoRecordEnabled) }
        set { defaults.set(newValue, forKey: Key.autoRecordEnabled) }
    }

    /// Auto-recording suppressed until this moment ("pause for 1 hour" / "until tomorrow").
    public var pausedUntil: Date? {
        get {
            let interval = defaults.double(forKey: Key.pausedUntil)
            guard interval > 0 else { return nil }
            let date = Date(timeIntervalSince1970: interval)
            return date > Date() ? date : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.pausedUntil) }
    }

    public var isAutoRecordActive: Bool { autoRecordEnabled && pausedUntil == nil }

    public func pause(for duration: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(duration)
    }

    public func pauseUntilTomorrow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        let tomorrow = calendar.startOfDay(for: Date().addingTimeInterval(24 * 3600))
        pausedUntil = tomorrow
    }

    public func resume() { pausedUntil = nil }

    public var notificationsEnabled: Bool {
        get { defaults.bool(forKey: Key.notificationsEnabled) }
        set { defaults.set(newValue, forKey: Key.notificationsEnabled) }
    }

    public var transcriptionEnabled: Bool {
        get { defaults.bool(forKey: Key.transcriptionEnabled) }
        set { defaults.set(newValue, forKey: Key.transcriptionEnabled) }
    }

    /// Hard stop for a runaway recording (plan.md §9.4).
    public var maxRecordingHours: Double {
        get { defaults.double(forKey: Key.maxRecordingHours) }
        set { defaults.set(newValue, forKey: Key.maxRecordingHours) }
    }

    public var startDebounce: TimeInterval {
        get { defaults.double(forKey: Key.startDebounce) }
        set { defaults.set(newValue, forKey: Key.startDebounce) }
    }

    public var stopDebounce: TimeInterval {
        get { defaults.double(forKey: Key.stopDebounce) }
        set { defaults.set(newValue, forKey: Key.stopDebounce) }
    }

    /// Which app to record. Overridable so the capture path can be pointed at a controllable
    /// audio source during testing — proving that *this* bundle holds system-audio permission
    /// needs a target that is definitely making sound, which Teams is not on demand.
    ///
    ///     defaults write com.raywong.MeetingRecorder targetBundlePrefixes -array com.apple.QuickTimePlayerX
    ///     defaults delete com.raywong.MeetingRecorder targetBundlePrefixes    # back to Teams
    public var targetBundlePrefixes: [String] {
        let stored = defaults.stringArray(forKey: Key.targetBundlePrefixes) ?? []
        return stored.isEmpty ? Coordinator.defaultTeamsBundlePrefixes : stored
    }

    /// Day-stamp of the last daily health check, so it runs once per day (plan.md §13).
    public var lastHealthCheckDay: String? {
        get { defaults.string(forKey: Key.lastHealthCheckDay) }
        set { defaults.set(newValue, forKey: Key.lastHealthCheckDay) }
    }

    // MARK: - Launch at login (plan.md §13)

    public var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("launch-at-login toggle failed: \(error.localizedDescription)")
            }
        }
    }

    public var launchAtLoginStatus: SMAppService.Status { SMAppService.mainApp.status }
}
