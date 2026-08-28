import AppKit
import OSLog
import RecorderKit
import SwiftUI

/// Asks for a meeting name before an in-person recording starts.
///
/// A floating panel rather than a sheet: the menu bar popover closes the moment its button is
/// pressed, so there is no window to attach a sheet to. `.nonactivatingPanel` is deliberately
/// *not* used here — unlike the alert panel, this one has to take keyboard focus.
@MainActor
final class TitlePrompt {
    static let shared = TitlePrompt()

    private static let log = Logger(subsystem: loggingSubsystem, category: "Windows")
    private var panel: NSPanel?

    private init() {}

    func ask(defaultTitle: String, onConfirm: @escaping (String) -> Void) {
        panel?.close()

        let view = TitlePromptView(
            title: defaultTitle,
            onConfirm: { [weak self] title in
                self?.dismiss()
                onConfirm(title)
            },
            onCancel: { [weak self] in self?.dismiss() })

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 140),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        panel.title = "Record In-Person Meeting"
        panel.contentView = NSHostingView(rootView: view)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.center()

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        // Activation is asynchronous, so the key state right now says nothing useful.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            Self.log.notice("name prompt — visible: \(panel.isVisible), key: \(panel.isKeyWindow)")
        }
    }

    private func dismiss() {
        panel?.close()
        panel = nil
    }
}

/// `NSPanel` refuses key status by default, which would leave the text field unfocused and the
/// user typing into nothing.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct TitlePromptView: View {
    @State var title: String
    var onConfirm: (String) -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What is this meeting?")
                .font(.headline)

            TextField("In-person meeting", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { confirm() }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Start Recording", action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            // A beat after the panel becomes key, or the focus request lands before there is a
            // key window to focus into.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true }
        }
    }

    private func confirm() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        onConfirm(trimmed.isEmpty ? "in-person meeting" : trimmed)
    }
}
