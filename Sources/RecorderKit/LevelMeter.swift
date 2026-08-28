import AVFoundation
import Foundation

public let loggingSubsystem = "com.raywong.meetingrecorder"

/// Running RMS over a capture stream.
///
/// This is the single most important defence in the project (plan.md §6.5, §15.1). Every
/// Core Audio call in the capture chain returns `noErr` whether or not TCC granted access;
/// a denied tap produces a perfectly valid file in which every sample is zero. Nothing else
/// — no error code, no log line — distinguishes that from a successful recording.
public final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var sumOfSquares: Double = 0
    private var sampleCount: Int = 0
    private var peak: Float = 0
    private var windowSum: Double = 0
    private var windowCount: Int = 0

    /// Below this RMS a stream is treated as silent. Real speech sits orders of magnitude
    /// above it; digital silence is exactly 0.
    public static let silenceThreshold: Float = 1e-5

    public init() {}

    public func accumulate(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let channelCount = Int(buffer.format.channelCount)

        // A process tap delivers *interleaved* float. `floatChannelData` then holds exactly
        // one pointer covering frames × channels, not one pointer per channel — walking it
        // per-channel reads off the end of the array.
        let pointerCount = buffer.format.isInterleaved ? 1 : channelCount
        let valuesPerPointer = buffer.format.isInterleaved ? frames * channelCount : frames

        var sum: Double = 0
        var localPeak: Float = 0
        for pointer in 0..<pointerCount {
            let samples = channels[pointer]
            for index in 0..<valuesPerPointer {
                let sample = samples[index]
                sum += Double(sample) * Double(sample)
                localPeak = max(localPeak, abs(sample))
            }
        }
        let count = frames * channelCount
        lock.lock()
        sumOfSquares += sum
        sampleCount += count
        windowSum += sum
        windowCount += count
        peak = max(peak, localPeak)
        lock.unlock()
    }

    /// RMS over everything seen so far.
    public var rms: Float {
        lock.lock(); defer { lock.unlock() }
        guard sampleCount > 0 else { return 0 }
        return Float((sumOfSquares / Double(sampleCount)).squareRoot())
    }

    public var peakAmplitude: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    public var framesSeen: Int {
        lock.lock(); defer { lock.unlock() }
        return sampleCount
    }

    public var isSilent: Bool { rms < Self.silenceThreshold }

    /// RMS since the last call, for the live meter and the mid-recording silence watchdog.
    public func consumeWindowRMS() -> Float {
        lock.lock(); defer { lock.unlock() }
        guard windowCount > 0 else { return 0 }
        let value = Float((windowSum / Double(windowCount)).squareRoot())
        windowSum = 0
        windowCount = 0
        return value
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        sumOfSquares = 0; sampleCount = 0; peak = 0; windowSum = 0; windowCount = 0
    }
}

public extension Float {
    /// dBFS, floored at -160 so a silent stream prints as a number rather than `-inf`.
    var asDecibels: Float { self <= 0 ? -160 : max(-160, 20 * log10(self)) }
}
