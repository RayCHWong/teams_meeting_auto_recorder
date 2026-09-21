@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Writes a capture stream to AAC `.m4a` incrementally.
///
/// Incremental by design: a meeting is never buffered in memory (plan.md §9.1). The cost is
/// that an unexpected termination can leave a truncated file, which is why `meta.json` is
/// written at start rather than at stop.
public final class AudioFileWriter: @unchecked Sendable {
    private static let log = Logger(subsystem: loggingSubsystem, category: "AudioFileWriter")

    public let url: URL
    public let meter = LevelMeter()

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private let processingFormat: AVAudioFormat
    private var inputFormat: AVAudioFormat
    private var didLogWriteFailure = false
    private(set) public var framesWritten: AVAudioFramePosition = 0

    /// When the first buffer actually arrived. The two streams do not start together — the
    /// microphone session is up before the tap is even created, and `AudioDeviceStart` can sit
    /// for seconds waiting on a permission prompt — so mixing them needs the real offset
    /// between them, not the moment the files were opened.
    private(set) public var firstBufferAt: Date?

    /// - Parameters:
    ///   - inputFormat: whatever the capture source actually delivers.
    ///   - channels: 2 for the far end, 1 for the microphone.
    ///   - bitRate: 128 kbps far end, 96 kbps mic.
    public init(url: URL, inputFormat: AVAudioFormat, channels: AVAudioChannelCount, bitRate: Int) throws {
        self.url = url
        self.inputFormat = inputFormat

        let sampleRate = 48_000.0
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channels),
            AVEncoderBitRateKey: bitRate,
        ]

        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        self.processingFormat = file.processingFormat

        self.converter = try Self.makeConverter(from: inputFormat, to: processingFormat)
    }

    /// Resample / down-mix only when the source disagrees with the file (plan.md §9.1).
    private static func makeConverter(from inputFormat: AVAudioFormat, to processingFormat: AVAudioFormat) throws -> AVAudioConverter? {
        guard inputFormat.sampleRate != processingFormat.sampleRate
            || inputFormat.channelCount != processingFormat.channelCount
            || inputFormat.commonFormat != processingFormat.commonFormat
            || inputFormat.isInterleaved != processingFormat.isInterleaved
        else { return nil }

        guard let converter = AVAudioConverter(from: inputFormat, to: processingFormat) else {
            throw RecorderError.formatConversionUnavailable(from: inputFormat, to: processingFormat)
        }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        return converter
    }

    /// Called from the capture thread. Never throws — a write failure mid-meeting must not
    /// take the process down; it is logged once and surfaced through `didFail`.
    public func append(_ buffer: AVAudioPCMBuffer) {
        meter.accumulate(buffer)
        lock.lock()
        defer { lock.unlock() }
        guard let file else { return }
        if firstBufferAt == nil, buffer.frameLength > 0 { firstBufferAt = Date() }
        // The capture source can change format under us — a headset swap, or Teams moving a
        // Bluetooth mic between A2DP and HFP. Rebuild the converter rather than writing the new
        // samples under the old format's label, which stretches or squeezes the whole file.
        if buffer.format != inputFormat {
            Self.log.warning("input format changed for \(self.url.lastPathComponent, privacy: .public): \(self.inputFormat.sampleRate, privacy: .public) Hz -> \(buffer.format.sampleRate, privacy: .public) Hz")
            inputFormat = buffer.format
            converter = (try? Self.makeConverter(from: buffer.format, to: processingFormat)) ?? nil
            if converter == nil, buffer.format != processingFormat {
                if !didLogWriteFailure {
                    didLogWriteFailure = true
                    Self.log.error("no converter for the new input format of \(self.url.lastPathComponent, privacy: .public)")
                }
                return
            }
        }
        do {
            if let converter {
                guard let converted = try convert(buffer, using: converter) else { return }
                try file.write(from: converted)
                framesWritten += AVAudioFramePosition(converted.frameLength)
            } else {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            if !didLogWriteFailure {
                didLogWriteFailure = true
                Self.log.error("write failed for \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter) throws -> AVAudioPCMBuffer? {
        let ratio = processingFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else { return nil }

        // AVAudioConverter pulls until it is told there is nothing left; this source yields
        // the one buffer we were handed, exactly once.
        let source = SingleBufferSource(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            source.next(outStatus)
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    public var didFail: Bool {
        lock.lock(); defer { lock.unlock() }
        return didLogWriteFailure
    }

    public var duration: TimeInterval {
        Double(framesWritten) / processingFormat.sampleRate
    }

    /// Closes the file explicitly (plan.md §9.1). Idempotent.
    public func close() {
        lock.lock()
        file = nil
        converter = nil
        lock.unlock()
    }

    public var fileSize: Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// One-shot buffer source for `AVAudioConverter`'s pull-style input block.
private final class SingleBufferSource: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer else {
            outStatus.pointee = .noDataNow
            return nil
        }
        self.buffer = nil
        outStatus.pointee = .haveData
        return buffer
    }
}

public enum RecorderError: LocalizedError {
    case formatConversionUnavailable(from: AVAudioFormat, to: AVAudioFormat)
    case teamsNotRunning
    case noAudioInputDevice
    case insufficientDiskSpace(freeBytes: Int64, requiredBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .formatConversionUnavailable(let from, let to):
            return "No converter from \(from) to \(to)"
        case .teamsNotRunning:
            return "Microsoft Teams is not running"
        case .noAudioInputDevice:
            return "No audio input device is available"
        case .insufficientDiskSpace(let free, let required):
            let formatter = ByteCountFormatter()
            return "Only \(formatter.string(fromByteCount: free)) free; \(formatter.string(fromByteCount: required)) required"
        }
    }
}
