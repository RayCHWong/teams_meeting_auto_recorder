import AVFoundation
import AppKit
import RecorderKit
import SwiftUI

/// The library window (plan.md §11).
///
/// Everything here comes from a disk scan — `meta.json` is the source of truth and there is no
/// separate database, so the recordings folder stays usable without the app.
struct LibraryView: View {
    @Bindable var coordinator: Coordinator

    @State private var recordings: [Recording] = []
    @State private var selection: Recording.ID?
    @State private var search = ""
    @State private var pendingDeletion: Recording?

    private var filtered: [Recording] {
        guard !search.isEmpty else { return recordings }
        return recordings.filter { $0.metadata.title.localizedCaseInsensitiveContains(search) }
    }

    private var selected: Recording? {
        filtered.first { $0.id == selection } ?? recordings.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarHeader
                Divider()
                List(filtered, selection: $selection) { recording in
                    RecordingRow(recording: recording, coordinator: coordinator).tag(recording.id)
                }
                .scrollContentBackground(.hidden)
            }
            // Wide enough for "28 Aug, 2:23 PM · 1:02:14 · manual" on one line without
            // truncating, which the previous 300 was not.
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 520)
        } detail: {
            if let selected {
                RecordingDetail(recording: selected) {
                    pendingDeletion = selected
                } onRename: { title in
                    let renamed = coordinator.rename(selected, to: title)
                    reload()
                    selection = renamed.id
                }
            } else {
                ContentUnavailableView(
                    recordings.isEmpty ? "No recordings yet" : "Select a recording",
                    systemImage: "waveform",
                    description: Text(recordings.isEmpty
                        ? "Recordings appear here automatically when you join a Teams call."
                        : ""))
            }
        }
        .task { reload() }
        .onChange(of: coordinator.state) { _, _ in reload() }
        .onChange(of: coordinator.processing) { _, _ in reload() }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { recording in
            Button("Move to Trash", role: .destructive) {
                try? coordinator.store.delete(recording)
                pendingDeletion = nil
                selection = nil
                reload()
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { recording in
            Text("“\(recording.metadata.title)” will be moved to the Trash.")
        }
    }

    /// Search field and the two library actions.
    ///
    /// Hand-built rather than `.searchable` + `.toolbar`: this window is a plain `NSWindow` with
    /// no `NSToolbar`, so SwiftUI toolbar items have nowhere to render, and a sidebar-placed
    /// search field sits flush against the title bar with no way to pad it.
    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search titles", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))

            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
            Button { NSWorkspace.shared.open(coordinator.store.root) } label: {
                Image(systemName: "folder")
            }
            .help("Open the recordings folder")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func reload() {
        recordings = coordinator.store.allRecordings()
        if selection == nil { selection = recordings.first?.id }
    }
}

private struct RecordingRow: View {
    let recording: Recording
    @Bindable var coordinator: Coordinator

    /// Elapsed time for the row that is being captured right now. Reading `coordinator.elapsed`
    /// here is what makes the row tick — the coordinator updates it once a second.
    private var liveElapsed: TimeInterval? {
        guard recording.directory == coordinator.currentDirectory,
              coordinator.state == .recording || coordinator.state == .finalizing
        else { return nil }
        return coordinator.elapsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(recording.metadata.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if liveElapsed != nil {
                    Circle().fill(.red).frame(width: 7, height: 7)
                } else if !recording.metadata.isFinished {
                    ProgressView()
                        .controlSize(.small)
                        .help("Combining audio and transcribing")
                } else if recording.metadata.hasSilentTrack {
                    // A recording that "worked" is not evidence of anything until something
                    // has checked the actual sample values (plan.md, preamble).
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("One track contains only silence")
                }
            }
            HStack(spacing: 6) {
                if recording.metadata.isFinished {
                    // Deliberately not `.abbreviated` + `.shortened`, which spells out
                    // "Aug 28, 2026 at 2:23 PM" and eats the whole row.
                    Text(recording.displayDate.formatted(
                        .dateTime.day().month(.abbreviated).hour().minute()))
                    if let duration = recording.metadata.duration {
                        Text("·")
                        Text(Coordinator.format(duration)).monospacedDigit()
                    }
                    if recording.metadata.trigger == .manual {
                        Text("·")
                        Text("manual")
                    }
                } else if let liveElapsed {
                    Text("Recording")
                        .foregroundStyle(.red)
                    Text(Coordinator.format(liveElapsed))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                } else {
                    Text(recording.metadata.status == .recording ? "Recording…" : "Processing…")
                        .foregroundStyle(.tint)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

private struct RecordingDetail: View {
    let recording: Recording
    var onDelete: () -> Void
    var onRename: (String) -> Void

    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    // Editable in place: the automatic name comes from a calendar entry and is
                    // not always what the meeting turned out to be about.
                    TextField("Title", text: $draftTitle)
                        .textFieldStyle(.plain)
                        .font(.title2).bold()
                        // Renaming moves the folder; doing that under a running mix would
                        // strand the background job on a path that no longer exists.
                        .disabled(!recording.metadata.isFinished)
                        .focused($titleFocused)
                        .onSubmit { commit() }
                        .onChange(of: titleFocused) { _, focused in if !focused { commit() } }
                        .onChange(of: recording.id) { _, _ in draftTitle = recording.metadata.title }
                        .onAppear { draftTitle = recording.metadata.title }
                    Text(recording.displayDate.formatted(date: .complete, time: .shortened))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        if let duration = recording.metadata.duration {
                            Label(Coordinator.format(duration), systemImage: "clock")
                        }
                        Label(ByteCountFormatter().string(fromByteCount: recording.totalSize), systemImage: "internaldrive")
                        Label(recording.metadata.trigger.rawValue, systemImage: "bolt")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !recording.metadata.isFinished {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recording.metadata.status == .recording
                                 ? "Recording in progress"
                                 : "Combining audio and transcribing")
                            Text("The combined file and transcript appear here when this finishes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                if recording.metadata.hasSilentTrack {
                    Label(
                        "One or more tracks contain only silence. That usually means system audio recording permission was denied.",
                        systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                // Only what you would actually play. When a combined file exists the raw sides
                // are kept in "original sound tracks" for re-mixing, not for browsing.
                VStack(alignment: .leading, spacing: 10) {
                    Text(recording.metadata.visibleTracks.count > 1 ? "Tracks" : "Recording")
                        .font(.headline)
                    ForEach(recording.metadata.visibleTracks, id: \.file) { track in
                        TrackPlayer(
                            track: track,
                            url: recording.directory.appendingPathComponent(track.file))
                    }
                }

                if !recording.metadata.attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Attendees").font(.headline)
                        Text(recording.metadata.attendees.joined(separator: ", "))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                if !recording.metadata.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.headline)
                        ForEach(Array(recording.metadata.notes.enumerated()), id: \.offset) { _, note in
                            Text("• \(note)")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button {
                        NSWorkspace.shared.selectFile(
                            recording.trackURLs.first?.path,
                            inFileViewerRootedAtPath: recording.directory.path)
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!recording.metadata.isFinished)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func commit() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != recording.metadata.title else {
            draftTitle = recording.metadata.title
            return
        }
        onRename(trimmed)
    }
}

/// Minimal transport for one track. `AVPlayer` rather than a full `VideoPlayer` — these are
/// audio files and a video surface would just be a black rectangle.
private struct TrackPlayer: View {
    let track: TrackMetadata
    let url: URL

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var observer: Any?

    private var trackSymbol: String {
        switch track.source {
        case .microphone: return "mic"
        case .system: return "speaker.wave.2"
        case .mixed: return "waveform"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: trackSymbol)
                Text(track.file).font(.callout).monospaced()
                if track.hasSilence {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(track.rmsOK
                              ? "One of the sides mixed into this file was silent"
                              : "This file contains only silence")
                }
                Spacer()
                if let rms = track.rms {
                    Text(String(format: "%.1f dBFS", rms.asDecibels))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 10) {
                Button {
                    toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .disabled(!FileManager.default.fileExists(atPath: url.path))

                Slider(value: $position, in: 0...max(duration, 0.01)) { editing in
                    if !editing { player?.seek(to: CMTime(seconds: position, preferredTimescale: 600)) }
                }
                Text(Coordinator.format(position))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .onDisappear { teardown() }
    }

    private func toggle() {
        if player == nil { setUp() }
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func setUp() {
        let player = AVPlayer(url: url)
        let asset = AVURLAsset(url: url)
        Task { duration = CMTimeGetSeconds((try? await asset.load(.duration)) ?? .zero) }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { time in
            // The observer is registered on the main queue, so this is already main-actor
            // isolated — the compiler just cannot see that through the Objective-C block.
            MainActor.assumeIsolated {
                position = CMTimeGetSeconds(time)
                if duration > 0, position >= duration - 0.05 { isPlaying = false }
            }
        }
        self.player = player
    }

    private func teardown() {
        if let observer { player?.removeTimeObserver(observer) }
        player?.pause()
        player = nil
        observer = nil
        isPlaying = false
    }
}
