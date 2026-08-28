import AVFoundation
import Foundation
import OSLog
import Speech

/// On-device transcription of a finished recording (plan.md §14).
///
/// `SpeechAnalyzer` with the `SpeechTranscriber` module — on-device only, built for long-form
/// audio, and the replacement for `SFSpeechRecognizer`.
///
/// The two tracks are transcribed **separately**, and that is the whole trick: it gives
/// speaker attribution for free — your track versus everyone else's — with no diarization.
///
/// Runs as a post-processing job after `FINALIZING`, never during the call.
@available(macOS 26.0, *)
public enum TranscriptionService {
    private static let log = Logger(subsystem: loggingSubsystem, category: "Transcription")

    public enum Failure: LocalizedError {
        case unavailable
        case localeUnsupported(Locale)
        case modelNotInstalled
        case noAudio

        public var errorDescription: String? {
            switch self {
            case .unavailable: return "Speech transcription is not available on this Mac"
            case .localeUnsupported(let locale): return "No transcription model for \(locale.identifier)"
            case .modelNotInstalled: return "The transcription model is still downloading"
            case .noAudio: return "No audio tracks to transcribe"
            }
        }
    }

    /// Which on-device model does the work.
    ///
    /// macOS Dictation itself is not an API — it is a live input method that types into the
    /// focused text field from the microphone, and cannot be pointed at a file. The *model*
    /// behind it is available though, as `DictationTranscriber`, alongside the newer long-form
    /// `SpeechTranscriber`. Both run entirely on this Mac with no network.
    public enum Model: String, CaseIterable, Sendable {
        /// Use long-form wherever it supports the language, downloading its model if needed;
        /// fall back to dictation only for the languages long-form does not cover.
        case automatic
        /// `SpeechTranscriber` — built for long-form audio, fewer locales.
        case longForm
        /// `DictationTranscriber` — the macOS Dictation model. Many more locales, and its
        /// assets are already present for any language enabled for keyboard dictation.
        case dictation

        public var title: String {
            switch self {
            case .automatic: return "Automatic (best available)"
            case .longForm: return "Long-form (best for meetings)"
            case .dictation: return "Dictation (macOS built-in)"
            }
        }
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    /// Downloads and installs a model ahead of time, so a real meeting never waits for it.
    @discardableResult
    public static func installModel(
        locale: Locale, model: Model = .automatic
    ) async throws -> (model: Model, locale: Locale) {
        guard let choice = await resolve(model, locale: locale) else {
            throw Failure.localeUnsupported(locale)
        }
        switch choice.model {
        case .longForm, .automatic:
            try await installAssets(
                for: SpeechTranscriber(locale: choice.locale, preset: .transcription),
                locale: choice.locale)
        case .dictation:
            try await installAssets(
                for: DictationTranscriber(locale: choice.locale, preset: .longDictation),
                locale: choice.locale)
        }
        return choice
    }

    /// Every locale either model can handle, for the settings picker.
    public static func availableLocales() async -> [Locale] {
        let combined = await SpeechTranscriber.supportedLocales + DictationTranscriber.supportedLocales
        var seen = Set<String>()
        return combined
            .filter { seen.insert($0.identifier).inserted }
            .sorted { $0.identifier < $1.identifier }
    }

    /// Picks the model and the exact locale to run it with.
    static func resolve(_ model: Model, locale: Locale) async -> (model: Model, locale: Locale)? {
        let longForm = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        let dictation = await DictationTranscriber.supportedLocale(equivalentTo: locale)

        switch model {
        case .longForm:
            return longForm.map { (.longForm, $0) }
        case .dictation:
            return dictation.map { (.dictation, $0) }
        case .automatic:
            // Quality first: long-form wherever it covers the language, even if that means a
            // one-time model download. Preferring whatever happened to be installed sounds
            // reasonable but produces the worst outcome in the case that matters — Cantonese is
            // supported by both, yet only dictation ships installed, so "prefer installed"
            // silently picks the weaker model for the language you most wanted the better one.
            // Dictation covers the 24 locales long-form does not, which is where it earns its
            // place.
            if let longForm { return (.longForm, longForm) }
            if let dictation { return (.dictation, dictation) }
            return nil
        }
    }

    /// Transcribes every track of a recording and writes `transcript.md` beside the audio.
    @discardableResult
    public static func transcribe(
        _ recording: Recording,
        locale: Locale = Locale(identifier: "en-US"),
        model: Model = .automatic
    ) async throws -> URL {
        guard !recording.metadata.tracks.isEmpty else { throw Failure.noAudio }

        // Resuming interrupted post-processing must not redo work that already succeeded.
        let destination = recording.directory.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        guard let choice = await resolve(model, locale: locale) else {
            throw Failure.localeUnsupported(locale)
        }
        Self.log.info("transcribing with \(choice.model.rawValue, privacy: .public) in \(choice.locale.identifier, privacy: .public)")

        // Only the combined file when there is one: the transcript should describe the
        // recording as you would play it, not the raw sides kept for re-mixing.
        let subjects = recording.metadata.hasMixedTrack
            ? recording.metadata.tracks.filter { $0.source == .mixed }
            : recording.metadata.tracks

        var sections: [(TrackMetadata, String)] = []
        for track in subjects {
            // A silent track has nothing to say and would only produce noise in the transcript.
            guard track.rmsOK else { continue }
            let url = recording.directory.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let text = try await transcribeFile(at: url, locale: choice.locale, model: choice.model)
            if !text.isEmpty { sections.append((track, text)) }
        }

        let markdown = render(recording: recording, sections: sections)
        try markdown.write(to: destination, atomically: true, encoding: .utf8)
        Self.log.info("wrote \(destination.lastPathComponent, privacy: .public) (\(sections.count) track(s))")
        return destination
    }

    // MARK: - One file

    static func transcribeFile(at url: URL, locale: Locale, model: Model) async throws -> String {
        let file = try AVAudioFile(forReading: url)

        switch model {
        case .longForm, .automatic:
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
            try await installAssets(for: transcriber, locale: locale)
            return try await run(transcriber, file: file) {
                var text = AttributedString()
                for try await result in transcriber.results { text.append(result.text) }
                return String(text.characters)
            }
        case .dictation:
            // Built explicitly rather than from the `.longDictation` preset, because that
            // preset does not punctuate — it is tuned for text being typed into a field, where
            // the user says "period". An unpunctuated wall of text is close to unreadable as a
            // meeting record, so punctuation is requested outright.
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [],
                attributeOptions: [])
            try await installAssets(for: transcriber, locale: locale)
            return try await run(transcriber, file: file) {
                var text = AttributedString()
                for try await result in transcriber.results { text.append(result.text) }
                return String(text.characters)
            }
        }
    }

    /// The models are downloadable assets; on a clean machine the first run has to fetch one.
    private static func installAssets(for module: any SpeechModule, locale: Locale) async throws {
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported:
            throw Failure.localeUnsupported(locale)
        case .supported, .downloading:
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                Self.log.notice("downloading the speech model for \(locale.identifier, privacy: .public) — first use of this language")
                try await request.downloadAndInstall()
                Self.log.notice("speech model for \(locale.identifier, privacy: .public) installed")
            }
        case .installed:
            break
        @unknown default:
            break
        }
    }

    /// Feeds the file through an analyzer and collects the module's results concurrently.
    private static func run(
        _ module: any SpeechModule,
        file: AVAudioFile,
        collect: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { try await collect() }
        _ = try await analyzer.analyzeSequence(from: file)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Output

    /// The words, and nothing else.
    ///
    /// No title, no date, no attendees, no per-track headings. The metadata all lives in
    /// `meta.json` next door, and repeating it here just puts something between the reader and
    /// the transcript.
    static func render(recording: Recording, sections: [(TrackMetadata, String)]) -> String {
        sections
            .map(\.1)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
