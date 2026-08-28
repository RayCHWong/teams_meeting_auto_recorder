import AppKit
import Foundation
import OSLog
import SwiftUI

/// Everything the app needs to tell the user, and the guarantee that it reaches them.
///
/// `UserNotifications` is the primary channel (plan.md §12), but on this machine
/// `requestAuthorization` returns `notificationsNotAllowed` for a locally-signed app: the
/// bundle never gets an entry in Notification Center's preferences, and no amount of
/// re-signing, re-registering, or Info.plist metadata changes it. That is a plausible state
/// for any Mac this ever runs on, and it silently disables exactly the warnings the project
/// exists to deliver — so it cannot be the only channel.
///
/// Every alert therefore also lands in an in-app inbox the menu bar surfaces, and is appended
/// to `alerts.log` next to the recordings. Critical ones (a stream capturing nothing, a
/// recording that failed to start) additionally raise a window, because a silent failure that
/// is only visible in a log is still a silent failure.
@MainActor
@Observable
public final class AlertCenter {
    public static let shared = AlertCenter()

    private static let log = Logger(subsystem: loggingSubsystem, category: "Alerts")

    public enum Severity: String, Sendable {
        case info
        case warning
        case critical
    }

    public struct Alert: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let severity: Severity
        public let title: String
        public let body: String
    }

    /// Most recent first, capped — this is an inbox, not an archive; `alerts.log` is the archive.
    public private(set) var recent: [Alert] = []
    public private(set) var unreadCount = 0

    /// True once `UserNotifications` has told us it will not deliver anything.
    public private(set) var systemNotificationsUnavailable = false

    public var logDirectory: URL = RecordingStore.defaultRoot

    private init() {}

    public func markNotificationsUnavailable() {
        guard !systemNotificationsUnavailable else { return }
        systemNotificationsUnavailable = true
        Self.log.error("system notifications are unavailable — falling back to the in-app inbox")
    }

    public func markAllRead() { unreadCount = 0 }

    public func post(
        _ severity: Severity,
        title: String,
        body: String,
        category: Notifications.Category,
        userInfo: [String: String] = [:]
    ) {
        let alert = Alert(date: Date(), severity: severity, title: title, body: body)
        recent.insert(alert, at: 0)
        if recent.count > 50 { recent.removeLast(recent.count - 50) }
        unreadCount += 1
        append(alert)

        Notifications.shared.post(
            category, title: title, body: body, userInfo: userInfo,
            interruptionLevel: severity == .critical ? .timeSensitive : .active)

        // A window is intrusive on purpose, and only when the system channel is known dead and
        // the news is bad enough to act on mid-meeting.
        if severity == .critical, systemNotificationsUnavailable {
            presentWindow(title: title, body: body)
        }
    }

    private var panel: NSPanel?

    /// A floating panel, deliberately **not** `NSAlert.runModal()`.
    ///
    /// A modal alert runs a nested run loop that starves everything scheduled in the default
    /// mode: the once-a-second level ticker stops, the silence watchdog stops, and the menu's
    /// stop control cannot be serviced until someone dismisses the dialog. Since the alert most
    /// likely to fire is "this recording is capturing silence" — raised *while recording* —
    /// blocking the app at that exact moment is the worst possible response to it.
    private func presentWindow(title: String, body: String) {
        panel?.close()

        let view = NSHostingView(rootView: CriticalAlertView(title: title, message: body) { [weak self] in
            self?.panel?.close()
            self?.panel = nil
        })
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 150),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.title = "Meeting Recorder"
        panel.contentView = view
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel
    }

    /// Dismisses the floating alert panel, if one is up.
    public func dismissPanel() {
        panel?.close()
        panel = nil
    }

    private func append(_ alert: Alert) {
        let stamp = ISO8601DateFormatter.localOffset().string(from: alert.date)
        let line = "\(stamp)  [\(alert.severity.rawValue)] \(alert.title) — \(alert.body)\n"
        let url = logDirectory.appendingPathComponent("alerts.log")
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: url)
            }
        } catch {
            Self.log.error("could not append to alerts.log: \(error.localizedDescription, privacy: .public)")
        }
    }
}


/// Contents of the floating critical-alert panel.
private struct CriticalAlertView: View {
    let title: String
    let message: String
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(title).font(.headline)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
    }
}
