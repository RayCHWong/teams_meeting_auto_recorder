import AVFoundation
import Foundation
import OSLog

/// Sums the microphone and far-end tracks into one file.
///
/// This runs **after** the call ends, never during it. Live mixing would mean summing two
/// streams that have no shared clock — the microphone device and the tap's aggregate device
/// drift apart over an hour — and getting it wrong corrupts the only copy. Capturing separately
/// and mixing afterwards keeps the realtime path exactly as it was, keeps the "a crash still
/// leaves usable audio" property, and lets the mix be redone if it ever comes out wrong.
///
/// Note the trade-off `plan.md` §3 was protecting against: a mixed file cannot be un-mixed.
/// Per-speaker transcription attribution comes from having the two sides in separate files, so
/// discarding them costs that. `RecorderSettings.outputMode` decides whether they are kept.
public enum AudioMixer {
    private static let log = Logger(subsystem: loggingSubsystem, category: "Mixer")

    public struct Input: Sendable {
        public let url: URL
        /// Seconds from the start of the mix to this track's first sample.
        public let offset: TimeInterval
        public let peak: Float

        public init(url: URL, offset: TimeInterval, peak: Float) {
            self.url = url
            self.offset = offset
            self.peak = peak
        }
    }

    public enum Failure: LocalizedError {
        case noInputs
        case noAudioTrack(URL)
        case emptyOutput

        public var errorDescription: String? {
            switch self {
            case .noInputs: return "Nothing to mix"
            case .noAudioTrack(let url): return "No audio track in \(url.lastPathComponent)"
            case .emptyOutput: return "The mix produced an empty file"
            }
        }
    }

    /// Mixes `inputs` into a single `.m4a` at `url`, preserving their relative start times.
    public static func mix(_ inputs: [Input], to url: URL) async throws {
        guard !inputs.isEmpty else { throw Failure.noInputs }

        let composition = AVMutableComposition()
        let audioMix = AVMutableAudioMix()
        var parameters: [AVMutableAudioMixInputParameters] = []

        // Both sides at full volume can sum past full scale. Scaling by the summed peaks is
        // conservative — the two rarely peak together, since people take turns — but it is
        // cheap and it guarantees the mix cannot clip.
        let combinedPeak = inputs.reduce(Float(0)) { $0 + $1.peak }
        let gain = combinedPeak > 0.95 ? 0.95 / combinedPeak : 1.0

        for input in inputs {
            let asset = AVURLAsset(url: input.url)
            guard let sourceTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw Failure.noAudioTrack(input.url)
            }
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0 else { continue }

            guard let track = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }

            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: CMTime(seconds: max(0, input.offset), preferredTimescale: 48_000))

            let parameter = AVMutableAudioMixInputParameters(track: track)
            parameter.setVolume(gain, at: .zero)
            parameters.append(parameter)
        }

        guard !parameters.isEmpty else { throw Failure.noInputs }
        audioMix.inputParameters = parameters

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw Failure.noInputs }
        session.audioMix = audioMix

        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .m4a)

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.int64Value ?? 0
        guard size > 0 else { throw Failure.emptyOutput }
        Self.log.info("mixed \(inputs.count) track(s) into \(url.lastPathComponent, privacy: .public) at gain \(gain)")
    }
}

/// Turns a finished recording's separate tracks into mixed ones, one per capture segment.
public enum RecordingMixer {
    private static let log = Logger(subsystem: loggingSubsystem, category: "Mixer")

    /// - Parameter removeSources: delete `mic.m4a` / `system.m4a` once the mix is verified.
    ///   Only ever true after a successful, non-empty export — a failed mix must never cost
    ///   the recording.
    public static func mixSegments(
        of recording: Recording,
        removeSources: Bool
    ) async -> RecordingMetadata {
        var metadata = recording.metadata
        let sources = metadata.tracks.filter { $0.source != .mixed }
        guard !sources.isEmpty else { return metadata }

        let bySegment = Dictionary(grouping: sources, by: \.effectiveSegment)
        var mixedTracks: [TrackMetadata] = []
        var mixedAll = true

        for segment in bySegment.keys.sorted() {
            let tracks = bySegment[segment] ?? []
            // A segment where nothing was captured has nothing worth mixing.
            let usable = tracks.filter { track in
                FileManager.default.fileExists(
                    atPath: recording.directory.appendingPathComponent(track.file).path)
            }
            guard !usable.isEmpty else { continue }

            let segmentStart = usable.compactMap(\.startOffset).min() ?? 0
            let inputs = usable.map { track in
                AudioMixer.Input(
                    url: recording.directory.appendingPathComponent(track.file),
                    offset: (track.startOffset ?? segmentStart) - segmentStart,
                    peak: track.peak ?? 0)
            }
            let filename = RecordingStore.trackRelativePath(source: .mixed, segment: segment)
            let destination = recording.directory.appendingPathComponent(filename)

            do {
                try await AudioMixer.mix(inputs, to: destination)
                // Carry the per-side silence forward. The combined file's own RMS is healthy as
                // long as *one* side had audio, so without this the warning disappears exactly
                // when it matters most.
                let silent = usable.filter { !$0.rmsOK }.map(\.source)
                if !silent.isEmpty {
                    let names = silent.map(\.rawValue).joined(separator: " and ")
                    metadata.notes.append(
                        "The \(names) side captured only silence; segment \(segment) of the combined file contains the other side only.")
                }
                mixedTracks.append(TrackMetadata(
                    file: filename,
                    source: .mixed,
                    rmsOK: usable.contains { $0.rmsOK },
                    rms: usable.compactMap(\.rms).max(),
                    segment: segment,
                    startOffset: segmentStart,
                    peak: usable.compactMap(\.peak).max(),
                    silentSources: silent.isEmpty ? nil : silent))
            } catch {
                mixedAll = false
                let note = "Could not mix segment \(segment): \(error.localizedDescription). The separate tracks were kept."
                metadata.notes.append(note)
                Self.log.error("\(note, privacy: .public)")
            }
        }

        guard !mixedTracks.isEmpty else { return metadata }

        if removeSources, mixedAll {
            for track in sources {
                try? FileManager.default.removeItem(
                    at: recording.directory.appendingPathComponent(track.file))
            }
            // Leave no empty "original sound tracks" folder behind.
            let originals = recording.directory.appendingPathComponent(
                RecordingStore.originalsFolderName, isDirectory: true)
            if let remaining = try? FileManager.default.contentsOfDirectory(atPath: originals.path),
               remaining.isEmpty {
                try? FileManager.default.removeItem(at: originals)
            }
            metadata.tracks = mixedTracks
        } else {
            metadata.tracks = mixedTracks + sources
        }
        return metadata
    }
}
