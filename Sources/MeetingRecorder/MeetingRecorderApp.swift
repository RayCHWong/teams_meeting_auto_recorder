import AppKit
import RecorderKit
import SwiftUI

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: delegate.coordinator)
        } label: {
            MenuBarLabel(coordinator: delegate.coordinator)
        }
        .menuBarExtraStyle(.window)

    }
}

struct MenuBarLabel: View {
    @Bindable var coordinator: Coordinator

    var body: some View {
        // The state must be readable at a glance; recording is a filled red dot (plan.md §10).
        // The elapsed time sits next to it while recording, so the menu does not have to be
        // opened to see how long a meeting has been running. Monospaced digits keep the menu bar
        // from shifting on every tick.
        HStack(spacing: 3) {
            Image(systemName: coordinator.menuBarSymbol)
                .symbolRenderingMode(coordinator.state == .recording ? .multicolor : .monochrome)
            if coordinator.state == .recording || coordinator.state == .finalizing {
                Text(Coordinator.format(coordinator.elapsed))
                    .monospacedDigit()
            }
        }
    }
}

enum WindowID {
    static let library = "library"
    static let settings = "settings"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = Coordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Authorization is requested at first launch, not at first recording, so a permission
        // problem surfaces while the user is looking at the app rather than mid-meeting (plan.md §12).
        Task {
            let granted = await Notifications.shared.configure()
            if !granted { AlertCenter.shared.markNotificationsUnavailable() }
            _ = await CalendarService().requestAccess()
            if MicCapture.authorizationStatus() == .notDetermined {
                _ = await MicCapture.requestAccess()
            }
            coordinator.runDailyHealthCheckIfNeeded()
        }
        coordinator.start()

        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Coordinator.Command.askInPerson, object: nil, queue: .main) { [coordinator] _ in
            Task { @MainActor in
                TitlePrompt.shared.ask(defaultTitle: "") { title in
                    coordinator.startInPersonByUser(title: title)
                }
            }
        }
        center.addObserver(forName: Coordinator.Command.openSettings, object: nil, queue: .main) { [coordinator] _ in
            Task { @MainActor in WindowController.shared.showSettings(coordinator: coordinator) }
        }
        center.addObserver(forName: Coordinator.Command.openLibrary, object: nil, queue: .main) { [coordinator] _ in
            Task { @MainActor in WindowController.shared.showLibrary(coordinator: coordinator) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
    }
}

extension Coordinator {
    var menuBarSymbol: String {
        // An unread critical alert outranks the recording state: a capture that is producing
        // silence must not look like a healthy recording.
        if AlertCenter.shared.unreadCount > 0,
           AlertCenter.shared.recent.first?.severity == .critical {
            return "exclamationmark.triangle.fill"
        }
        switch state {
        case .idle: return "waveform"
        case .armed: return "waveform.badge.magnifyingglass"
        case .recording: return "record.circle.fill"
        case .finalizing: return "waveform.badge.exclamationmark"
        }
    }

    var statusText: String {
        switch state {
        case .idle:
            if !teamsIsRunning { return "Teams is not running" }
            return RecorderSettings.shared.isAutoRecordActive ? "Waiting for a Teams call" : "Auto-recording paused"
        case .armed: return "Teams audio detected…"
        case .recording: return "Recording"
        case .finalizing: return "Call ended — finishing"
        }
    }
}
