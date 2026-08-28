import AVFoundation
import AppKit
import EventKit
import RecorderKit
import SwiftUI

/// Settings, plus the permission panel.
///
/// The permission rows are not decoration. Every failure in plan.md §15 shows up here first:
/// a denied capture permission is invisible everywhere else in macOS until you notice that a
/// recording contains nothing.
struct SettingsView: View {
    @Bindable var coordinator: Coordinator

    @State private var launchAtLogin = RecorderSettings.shared.launchAtLogin
    @State private var autoRecord = RecorderSettings.shared.autoRecordEnabled
    @State private var maxHours = RecorderSettings.shared.maxRecordingHours
    @State private var transcription = RecorderSettings.shared.transcriptionEnabled
    @State private var outputMode = RecorderSettings.shared.outputMode
    @State private var speechLocale = RecorderSettings.shared.transcriptionLocale.identifier
    @State private var systemAudio: SystemAudioPermission.Status = .unknown
    @State private var probing = false
    @State private var micStatus = MicCapture.authorizationStatus()
    @State private var calendarStatus = CalendarService.authorizationStatus

    private var settings: RecorderSettings { .shared }

    var body: some View {
        Form {
            Section("Recording") {
                Toggle("Record Teams calls automatically", isOn: $autoRecord)
                    .onChange(of: autoRecord) { _, value in settings.autoRecordEnabled = value }

                LabeledContent("Save to") {
                    HStack {
                        Text(settings.recordingsRoot.path)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Button("Reveal") { NSWorkspace.shared.open(settings.recordingsRoot) }
                    }
                }

                Picker("Save as", selection: $outputMode) {
                    ForEach(RecorderSettings.OutputMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: outputMode) { _, value in settings.outputMode = value }
                if outputMode == .mixed {
                    Text("The two sides are captured separately and combined after the call. A combined file cannot be split again, so transcripts lose the “you versus everyone else” split.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Stop runaway recordings after", selection: $maxHours) {
                    Text("2 hours").tag(2.0)
                    Text("4 hours").tag(4.0)
                    Text("8 hours").tag(8.0)
                }
                .onChange(of: maxHours) { _, value in settings.maxRecordingHours = value }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, value in
                        settings.launchAtLogin = value
                        launchAtLogin = settings.launchAtLogin
                    }
                Text("A daily health check compares yesterday's meetings against what was actually recorded, and tells you when a meeting produced nothing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                // macOS exposes no authorization-status API for system audio capture, so this
                // row reports measured evidence rather than a queried state: what the last
                // recording actually captured, or the result of an explicit test.
                PermissionRow(
                    title: "System audio",
                    detail: systemAudioDetail,
                    state: systemAudioState,
                    action: { openPrivacy("Privacy_AudioCapture") },
                    accessory: {
                        Button(probing ? "Testing…" : "Test") {
                            probing = true
                            Task {
                                let ok = await SystemAudioPermission.probe()
                                systemAudio = ok ? .working(Date()) : .silent(Date())
                                probing = false
                            }
                        }
                        .disabled(probing)
                        .help("Plays a short tone and listens for it")
                    })
                PermissionRow(
                    title: "Microphone",
                    detail: "Your side of the call.",
                    state: micStatus == .authorized ? .granted : (micStatus == .denied ? .denied : .unknown),
                    action: { openPrivacy("Privacy_Microphone") },
                    accessory: { EmptyView() })
                PermissionRow(
                    title: "Calendar",
                    detail: "Names recordings after the matching meeting.",
                    state: calendarStatus == .fullAccess ? .granted : (calendarStatus == .denied ? .denied : .unknown),
                    action: { openPrivacy("Privacy_Calendars") },
                    accessory: { EmptyView() })
            }

            Section("Transcription") {
                if #available(macOS 26.0, *) {
                    TranscriptionSettings(transcription: $transcription, speechLocale: $speechLocale)
                } else {
                    // Everything else in the app works on macOS 15; the Speech framework is the
                    // one thing that does not exist before macOS 26.
                    Text("On-device transcription requires macOS 26. Recording works without it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .onAppear {
            systemAudio = SystemAudioPermission.inferred(from: coordinator.store.allRecordings())
            micStatus = MicCapture.authorizationStatus()
            calendarStatus = CalendarService.authorizationStatus
            launchAtLogin = settings.launchAtLogin
            outputMode = settings.outputMode
        }
    }

    private var systemAudioState: PermissionState {
        switch systemAudio {
        case .working: return .granted
        case .silent: return .denied
        case .unknown: return .unknown
        }
    }

    private var systemAudioDetail: String {
        switch systemAudio {
        case .working(let date):
            guard let date else { return "Working." }
            return "Captured far-end audio \(date.formatted(date: .abbreviated, time: .shortened))."
        case .silent:
            return "A recording captured only silence. Grant access, then test again."
        case .unknown:
            return "Required. Without it every recording is silent, with no error. Not yet verified."
        }
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

/// Standalone rather than nested, so it can be named without the row's generic parameter.
enum PermissionState { case granted, denied, unknown }

struct PermissionRow<Accessory: View>: View {
    let title: String
    let detail: String
    let state: PermissionState
    var action: () -> Void
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory()
            Button("Open…", action: action)
        }
    }

    private var symbol: String {
        switch state {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch state {
        case .granted: return .green
        case .denied: return .red
        case .unknown: return .secondary
        }
    }
}


/// The transcription controls, which only exist where the Speech framework does.
@available(macOS 26.0, *)
private struct TranscriptionSettings: View {
    @Binding var transcription: Bool
    @Binding var speechLocale: String

    @State private var speechModel = RecorderSettings.shared.transcriptionModel
    @State private var localeOptions: [Locale] = []

    private var settings: RecorderSettings { .shared }

    var body: some View {
        Toggle("Transcribe after each recording", isOn: $transcription)
            .onChange(of: transcription) { _, value in settings.transcriptionEnabled = value }

        Picker("Model", selection: $speechModel) {
            ForEach(TranscriptionService.Model.allCases, id: \.self) { model in
                Text(model.title).tag(model)
            }
        }
        .disabled(!transcription)
        .onChange(of: speechModel) { _, value in settings.transcriptionModel = value }

        Picker("Spoken language", selection: $speechLocale) {
            ForEach(localeOptions, id: \.identifier) { locale in
                Text(locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                    .tag(locale.identifier)
            }
        }
        .disabled(!transcription || localeOptions.isEmpty)
        .onChange(of: speechLocale) { _, value in
            settings.transcriptionLocale = Locale(identifier: value)
        }

        Text("Runs entirely on this Mac after the call ends, never during it. \u{201C}Dictation\u{201D} is the model behind macOS Dictation — it covers far more languages, and its assets are already installed for anything you have enabled for keyboard dictation.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .task {
                localeOptions = await TranscriptionService.availableLocales()
                if !localeOptions.contains(where: { $0.identifier == speechLocale }) {
                    speechLocale = localeOptions.first(where: { $0.identifier.hasPrefix("en") })?.identifier
                        ?? localeOptions.first?.identifier ?? speechLocale
                }
            }
    }
}
