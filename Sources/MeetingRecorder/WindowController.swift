import AppKit
import OSLog
import RecorderKit
import SwiftUI

/// Owns the Library and Settings windows.
///
/// SwiftUI `Window` scenes are opened through `@Environment(\.openWindow)`, which is only
/// reachable from inside a `View`. In a `LSUIElement` app the only always-present view is the
/// menu bar label, and its `onAppear` does not fire — so there is no view from which to capture
/// the action, and nothing outside the popover can open a window at all. Managing the two
/// windows with AppKit instead makes opening them an ordinary function call, from the menu, from
/// a notification action, or from the command hook used to test them.
@MainActor
final class WindowController {
    static let shared = WindowController()

    private static let log = Logger(subsystem: loggingSubsystem, category: "Windows")
    private var windows: [String: NSWindow] = [:]

    private init() {}

    func showLibrary(coordinator: Coordinator) {
        show(
            id: WindowID.library,
            title: "Recordings",
            size: NSSize(width: 1060, height: 620),
            content: LibraryView(coordinator: coordinator))
    }

    func showSettings(coordinator: Coordinator) {
        show(
            id: WindowID.settings,
            title: "Meeting Recorder Settings",
            size: NSSize(width: 520, height: 620),
            content: SettingsView(coordinator: coordinator))
    }

    private func show(id: String, title: String, size: NSSize, content: some View) {
        NSApp.activate(ignoringOtherApps: true)

        if let window = windows[id] {
            window.makeKeyAndOrderFront(nil)
            Self.log.notice("re-showing window \(id, privacy: .public) — visible: \(window.isVisible)")
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = title
        window.contentView = NSHostingView(rootView: content)
        // Without this the window is deallocated on close and reopening crashes.
        window.isReleasedWhenClosed = false
        window.center()
        // Remember size and position, so a sidebar or window the user widens stays widened.
        window.setFrameAutosaveName("com.raywong.MeetingRecorder.\(id)")
        window.makeKeyAndOrderFront(nil)
        windows[id] = window
        Self.log.notice("opened window \(id, privacy: .public) — \(Int(window.frame.width))×\(Int(window.frame.height))")
    }
}
