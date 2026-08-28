import Foundation
import OSLog
import UserNotifications

/// User-facing notifications.
///
/// The zero-sample and failure notifications are the ones that matter. Silent failure is the
/// dominant way this kind of tool dies — the user finds out three weeks later that nothing
/// has recorded since an OS update (plan.md §12).
public final class Notifications: NSObject, @unchecked Sendable {
    public static let shared = Notifications()

    private static let log = Logger(subsystem: loggingSubsystem, category: "Notifications")

    public enum Category: String, Sendable {
        case started = "recording.started"
        case stopped = "recording.stopped"
        case silent = "recording.silent"
        case failure = "recording.failure"
        case healthCheck = "recording.healthcheck"
    }

    public enum Action: String, Sendable {
        case stop = "action.stop"
        case open = "action.open"
        case reveal = "action.reveal"
        case openSettings = "action.settings"
        case openLog = "action.log"
    }

    /// Set by the app so notification buttons can reach the coordinator.
    public var actionHandler: (@Sendable (Action, [String: String]) -> Void)?

    private var isAuthorized = false

    private override init() { super.init() }

    /// Requested at first launch, not at first recording (plan.md §12).
    @discardableResult
    public func configure() async -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            category(.started, actions: [(.stop, "Stop", [.destructive])]),
            category(.stopped, actions: [(.open, "Open", []), (.reveal, "Reveal in Finder", [])]),
            category(.silent, actions: [(.openSettings, "Open Settings", [.foreground])]),
            category(.failure, actions: [(.openLog, "Open Log", [.foreground])]),
            category(.healthCheck, actions: [(.openSettings, "Open Settings", [.foreground])]),
        ])
        // Plain authorization first; if the system refuses outright, try provisional, which
        // grants quiet delivery without a prompt. Both can fail for a locally-signed app — the
        // caller is told so it can fall back to the in-app inbox.
        for options in [UNAuthorizationOptions([.alert, .sound]), UNAuthorizationOptions([.provisional, .alert])] {
            do {
                isAuthorized = try await center.requestAuthorization(options: options)
                if isAuthorized {
                    Self.log.info("notification authorization granted")
                    return true
                }
            } catch {
                Self.log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return false
    }

    private func category(
        _ identifier: Category,
        actions: [(Action, String, UNNotificationActionOptions)]
    ) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: identifier.rawValue,
            actions: actions.map { UNNotificationAction(identifier: $0.0.rawValue, title: $0.1, options: $0.2) },
            intentIdentifiers: [],
            options: [])
    }

    public func post(
        _ category: Category,
        title: String,
        body: String,
        userInfo: [String: String] = [:],
        interruptionLevel: UNNotificationInterruptionLevel = .active
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        content.userInfo = userInfo
        content.interruptionLevel = interruptionLevel

        guard isAuthorized else { return }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.log.error("post failed: \(error.localizedDescription, privacy: .public)") }
        }
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let action = Action(rawValue: response.actionIdentifier) else { return }
        let userInfo = response.notification.request.content.userInfo.reduce(into: [String: String]()) { result, pair in
            if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
        }
        actionHandler?(action, userInfo)
    }
}
