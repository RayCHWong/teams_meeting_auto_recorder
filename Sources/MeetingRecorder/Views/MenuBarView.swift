import RecorderKit
import SwiftUI

/// The menu bar popover: state at a glance, and the controls that matter mid-meeting.
///
/// The manual stop is the most important control here — there will be meetings you want to
/// stop recording partway through (plan.md §10).
struct MenuBarView: View {
    @Bindable var coordinator: Coordinator

    private var settings: RecorderSettings { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if coordinator.state == .recording || coordinator.state == .finalizing {
                levels
                Button(role: .destructive) {
                    coordinator.stopByUser()
                } label: {
                    Label("Stop Recording", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .keyboardShortcut(".", modifiers: [.command])
            } else {
                Button {
                    coordinator.startByUser()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .help("For a call the detector missed")

                Button {
                    // Named up front: an in-person meeting has no calendar entry to borrow a
                    // name from, and "ad-hoc meeting" tells you nothing six months later.
                    TitlePrompt.shared.ask(defaultTitle: "") { title in
                        coordinator.startInPersonByUser(title: title)
                    }
                } label: {
                    Label("Record In-Person Meeting", systemImage: "person.2.wave.2")
                        .frame(maxWidth: .infinity)
                }
                .help("Microphone only — no system audio, for a meeting in the room")
            }

            Divider()
            pauseControls
            Divider()

            HStack {
                Button("Library…") { WindowController.shared.showLibrary(coordinator: coordinator) }
                Spacer()
                Button("Settings…") { WindowController.shared.showSettings(coordinator: coordinator) }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
        // The alert inbox used to live here and clearing it was what reset the menu bar warning
        // icon. With the inbox gone, opening the menu is the "you have seen it" signal —
        // otherwise the warning triangle would stay lit permanently after the first alert.
        .onAppear { AlertCenter.shared.markAllRead() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 9, height: 9)
                Text(coordinator.statusText)
                    .font(.headline)
            }
            if let title = coordinator.currentTitle {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if coordinator.state == .recording {
                Text(Coordinator.format(coordinator.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .monospacedDigit()
            }
            if let error = coordinator.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var indicatorColor: Color {
        switch coordinator.state {
        case .idle: return coordinator.meetingAppIsRunning ? .secondary : Color.secondary.opacity(0.4)
        case .armed: return .yellow
        case .recording: return .red
        case .finalizing: return .orange
        }
    }

    private var levels: some View {
        VStack(alignment: .leading, spacing: 6) {
            LevelBar(label: "Far end", level: coordinator.systemLevel)
            LevelBar(label: "Mic", level: coordinator.micLevel)
        }
    }

    @ViewBuilder
    private var pauseControls: some View {
        if let until = settings.pausedUntil {
            HStack {
                Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Resume") { settings.resume() }
            }
        } else {
            Menu("Pause Auto-Recording") {
                Button("For 1 hour") { settings.pause(for: 3600) }
                Button("Until tomorrow") { settings.pauseUntilTomorrow() }
            }
            .fixedSize()
        }
    }

}

/// A live meter. Silence reads as an empty red bar, which is the point — a stream that has
/// gone quiet is visible here before the notification fires.
struct LevelBar: View {
    let label: String
    let level: Float

    private var fraction: Double {
        let decibels = Double(level.asDecibels)   // -60 dBFS … 0, clamped
        return min(1, max(0, (decibels + 60) / 60))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(fraction > 0.02 ? Color.accentColor : Color.red.opacity(0.6))
                        .frame(width: max(2, geometry.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }
}
