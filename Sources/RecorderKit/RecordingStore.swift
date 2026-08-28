import Foundation
import OSLog

/// One audio file inside a recording.
public struct TrackMetadata: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case microphone
        case system
        /// Both sides summed into one file. Convenient to play, impossible to take apart again.
        case mixed
    }

    public var file: String
    public var source: Source
    /// Result of the non-zero sample check (plan.md §6.5). `false` means the file exists, is
    /// valid, and contains nothing but silence — the failure this whole project is shaped
    /// around.
    public var rmsOK: Bool
    public var rms: Float?
    /// Which capture segment this file belongs to. Segments are the discontinuities — a sleep,
    /// a Teams restart — and audio is never mixed across one.
    public var segment: Int?
    /// Seconds from the recording's `actual_start` to this track's first sample.
    public var startOffset: Double?
    /// Highest sample seen, used to pick a mix gain that will not clip.
    public var peak: Float?
    /// On a mixed track, which of the sides that went into it contained only silence.
    ///
    /// Without this, mixing destroys the signal this whole project is built to surface: a
    /// combined file containing a good microphone track and a dead far-end track has a
    /// perfectly healthy RMS, so `rms_ok` is true and nothing warns anybody.
    public var silentSources: [Source]?

    enum CodingKeys: String, CodingKey {
        case file, source, rms, segment, peak
        case rmsOK = "rms_ok"
        case startOffset = "start_offset"
        case silentSources = "silent_sources"
    }

    /// The segment this file belongs to, falling back to the number in its name.
    ///
    /// `meta.json` files written before segments were recorded have no `segment` field, and
    /// treating every track in one as segment 1 would stack sequential segments on top of each
    /// other in a mix instead of laying them end to end.
    public var effectiveSegment: Int {
        if let segment { return segment }
        // "system.002.m4a" -> 2; "system.m4a" -> 1
        let parts = file.split(separator: ".")
        if parts.count >= 3, let parsed = Int(parts[parts.count - 2]) { return parsed }
        return 1
    }

    public init(
        file: String, source: Source, rmsOK: Bool, rms: Float? = nil,
        segment: Int? = nil, startOffset: Double? = nil, peak: Float? = nil,
        silentSources: [Source]? = nil
    ) {
        self.file = file
        self.source = source
        self.rmsOK = rmsOK
        self.rms = rms
        self.segment = segment
        self.startOffset = startOffset
        self.peak = peak
        self.silentSources = silentSources
    }

    /// True if this file, or any side that was mixed into it, captured nothing.
    public var hasSilence: Bool { !rmsOK || !(silentSources ?? []).isEmpty }
}

/// `meta.json` — the source of truth for a recording (plan.md §9.3).
///
/// Written at start and updated at stop, so a crash mid-meeting still leaves identifiable
/// audio. The library reads these off disk rather than keeping a database, which also means
/// the folder stays usable without the app.
public struct RecordingMetadata: Codable, Sendable, Equatable {
    public enum Trigger: String, Codable, Sendable {
        case auto
        case manual
    }

    /// Where a recording is in its life cycle.
    ///
    /// Persisted rather than held in memory, so the library can show it after a restart and so a
    /// recording interrupted by a crash is identifiable rather than silently half-finished.
    public enum Status: String, Codable, Sendable {
        /// Capture in progress.
        case recording
        /// Capture done; mixing and transcription still running.
        case processing
        case complete
    }

    public var schema: Int = 1
    public var eventID: String?
    public var title: String
    public var organizer: String?
    public var attendees: [String]
    public var scheduledStart: Date?
    public var scheduledEnd: Date?
    public var actualStart: Date
    public var actualEnd: Date?
    public var trigger: Trigger
    /// Absent in files written before this existed — those are all finished, so treat as complete.
    public var status: Status?
    public var tracks: [TrackMetadata]
    /// Warnings worth keeping: sleep restarts, device changes, calendar misses.
    public var notes: [String]

    enum CodingKeys: String, CodingKey {
        case schema, title, organizer, attendees, trigger, tracks, notes, status
        case eventID = "event_id"
        case scheduledStart = "scheduled_start"
        case scheduledEnd = "scheduled_end"
        case actualStart = "actual_start"
        case actualEnd = "actual_end"
    }

    public var duration: TimeInterval? {
        actualEnd.map { $0.timeIntervalSince(actualStart) }
    }

    public var hasSilentTrack: Bool { tracks.contains { $0.hasSilence } }

    public var isFinished: Bool { (status ?? .complete) == .complete }

    /// Whether this recording carries a combined file. The library shows only those when they
    /// exist — the raw sides are kept for re-mixing, not for browsing.
    public var hasMixedTrack: Bool { tracks.contains { $0.source == .mixed } }

    /// What the library should list.
    public var visibleTracks: [TrackMetadata] {
        hasMixedTrack ? tracks.filter { $0.source == .mixed } : tracks
    }

    public init(meeting: MeetingInfo, actualStart: Date, trigger: Trigger) {
        self.eventID = meeting.eventIdentifier
        self.title = meeting.title
        self.organizer = meeting.organizer
        self.attendees = meeting.attendees
        self.scheduledStart = meeting.scheduledStart
        self.scheduledEnd = meeting.scheduledEnd
        self.actualStart = actualStart
        self.trigger = trigger
        self.status = .recording
        self.tracks = []
        self.notes = []
    }
}

/// A recording on disk: a directory plus its `meta.json`.
public struct Recording: Identifiable, Sendable, Equatable {
    public var id: URL { directory }
    public var directory: URL
    public var metadata: RecordingMetadata

    public init(directory: URL, metadata: RecordingMetadata) {
        self.directory = directory
        self.metadata = metadata
    }

    public var displayDate: Date { metadata.actualStart }
    public var trackURLs: [URL] { metadata.tracks.map { directory.appendingPathComponent($0.file) } }

    public var totalSize: Int64 {
        trackURLs.reduce(0) { total, url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}

/// Owns the recordings directory: naming, `meta.json`, and the library scan.
public final class RecordingStore: @unchecked Sendable {
    private static let log = Logger(subsystem: loggingSubsystem, category: "RecordingStore")

    public static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings/Meetings", isDirectory: true)

    /// Refuse to start below this much free space (plan.md §9.4).
    public static let minimumFreeBytes: Int64 = 5 * 1024 * 1024 * 1024

    public let root: URL

    public init(root: URL = RecordingStore.defaultRoot) {
        self.root = root
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601WithTimeZone
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithTimeZone
        return decoder
    }()

    // MARK: - Creating

    public func freeBytes() -> Int64 {
        let values = try? root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    public func checkDiskSpace() throws {
        let free = freeBytes()
        guard free >= Self.minimumFreeBytes else {
            throw RecorderError.insufficientDiskSpace(freeBytes: free, requiredBytes: Self.minimumFreeBytes)
        }
    }

    /// Creates `YYYY-MM-DD_HHMM_<slug>/`, appending `-2`, `-3`… on collision (plan.md §9.2).
    public func makeDirectory(for meeting: MeetingInfo, at date: Date) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let base = "\(Self.timestamp(date))_\(Self.slug(meeting.title))"
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        return formatter.string(from: date)
    }

    /// Lowercase `[a-z0-9-]`, repeats collapsed, capped at 60 characters (plan.md §9.2).
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var result = ""
        var lastWasDash = false
        for character in folded {
            if character.isLetter && character.isASCII || character.isNumber && character.isASCII {
                result.append(character)
                lastWasDash = false
            } else if !lastWasDash, !result.isEmpty {
                result.append("-")
                lastWasDash = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        if result.count > 60 { result = String(result.prefix(60)) }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "untitled" : result
    }

    /// Where the raw per-side captures live, so the combined file is the only thing at the top
    /// level of a recording folder.
    public static let originalsFolderName = "original sound tracks"

    /// Path of a track *relative to the recording folder*. Mixed output sits at the top level;
    /// the raw sides go in the originals subfolder.
    public static func trackRelativePath(source: TrackMetadata.Source, segment: Int) -> String {
        let name = trackFilename(source: source, segment: segment)
        return source == .mixed ? name : "\(originalsFolderName)/\(name)"
    }

    /// `system.m4a`, then `system.002.m4a`, `system.003.m4a` … for segments created when the
    /// tap has to be rebuilt after sleep or a Teams restart (plan.md §9.4).
    public static func trackFilename(source: TrackMetadata.Source, segment: Int) -> String {
        let base: String
        switch source {
        case .microphone: base = "mic"
        case .system: base = "system"
        case .mixed: base = "recording"
        }
        return segment <= 1 ? "\(base).m4a" : String(format: "%@.%03d.m4a", base, segment)
    }

    // MARK: - meta.json

    public func writeMetadata(_ metadata: RecordingMetadata, to directory: URL) {
        do {
            let data = try Self.encoder.encode(metadata)
            try data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            Self.log.error("could not write meta.json in \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func readMetadata(in directory: URL) -> RecordingMetadata? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("meta.json")) else { return nil }
        return try? Self.decoder.decode(RecordingMetadata.self, from: data)
    }

    // MARK: - Library

    /// Reverse-chronological scan of the recordings root (plan.md §11).
    public func allRecordings() -> [Recording] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }

        return entries.compactMap { url -> Recording? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let metadata = readMetadata(in: url)
            else { return nil }
            return Recording(directory: url, metadata: metadata)
        }
        .sorted { $0.displayDate > $1.displayDate }
    }

    /// Renames a recording: rewrites the title in `meta.json` and moves the folder to match.
    ///
    /// The folder is renamed too, because its name is derived from the title and a folder that
    /// disagrees with the title it contains is the kind of thing that is confusing a year later.
    /// If the move fails the title change is still saved — a stale folder name is a much smaller
    /// problem than a lost rename.
    @discardableResult
    public func rename(_ recording: Recording, to title: String) -> Recording {
        var metadata = recording.metadata
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.title = trimmed.isEmpty ? metadata.title : trimmed

        let base = "\(Self.timestamp(metadata.actualStart))_\(Self.slug(metadata.title))"
        var destination = root.appendingPathComponent(base, isDirectory: true)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path),
              destination.standardizedFileURL != recording.directory.standardizedFileURL {
            destination = root.appendingPathComponent("\(base)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        if destination.standardizedFileURL != recording.directory.standardizedFileURL {
            do {
                try FileManager.default.moveItem(at: recording.directory, to: destination)
            } catch {
                Self.log.error("could not rename folder: \(error.localizedDescription, privacy: .public)")
                destination = recording.directory
            }
        }
        writeMetadata(metadata, to: destination)
        return Recording(directory: destination, metadata: metadata)
    }

    public func delete(_ recording: Recording) throws {
        try FileManager.default.trashItem(at: recording.directory, resultingItemURL: nil)
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// ISO-8601 with the local offset, as in the plan's sample `meta.json` (`…-04:00`).
    static var iso8601WithTimeZone: Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601DateFormatter.localOffset().string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    static var iso8601WithTimeZone: Self {
        .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.localOffset().date(from: text) { return date }
            if let date = ISO8601DateFormatter().date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
        }
    }
}

extension ISO8601DateFormatter {
    /// A fresh formatter per call: `ISO8601DateFormatter` is not `Sendable`, and metadata is
    /// written a handful of times per meeting, so sharing one is not worth the lock.
    static func localOffset() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "America/Toronto") ?? .current
        return formatter
    }
}
