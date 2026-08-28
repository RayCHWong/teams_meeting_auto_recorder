import AVFoundation
import Foundation
import OSLog

/// Answers "can this app actually record system audio?"
///
/// There is no authorization-status API for system audio capture — no
/// `AVCaptureDevice.authorizationStatus` equivalent, and `CGPreflightScreenCaptureAccess` covers
/// a different TCC service. Every call in the capture chain returns `noErr` whether or not
/// permission was granted (plan.md §6.4). The only ground truth is the sample values, which is
/// the thesis of this whole project, so the check is an actual measurement rather than a query.
///
/// Two ways to get an answer:
///
///   * `inferred(from:)` — passive. Did the most recent recordings capture far-end audio?
///     Costs nothing and is usually enough.
///   * `probe()` — active and deterministic. Plays a short tone from this process and taps
///     itself. Does not depend on anything else making noise, so silence is a real answer.
public enum SystemAudioPermission {
    private static let log = Logger(subsystem: loggingSubsystem, category: "Permission")

    public enum Status: Sendable, Equatable {
        /// Far-end audio was captured — permission is working.
        case working(Date?)
        /// A capture produced nothing but silence. Usually a denied permission.
        case silent(Date?)
        /// Nothing recorded yet, so nothing to conclude.
        case unknown
    }

    /// What the recordings on disk imply, newest first.
    public static func inferred(from recordings: [Recording]) -> Status {
        for recording in recordings {
            let systemTracks = recording.metadata.tracks.filter {
                $0.source == .system || $0.source == .mixed
            }
            guard !systemTracks.isEmpty else { continue }

            // On a combined file the far end is only known to have worked if it was not one of
            // the sides recorded as silent.
            let captured = systemTracks.contains { track in
                track.rmsOK && !(track.silentSources ?? []).contains(.system)
            }
            return captured
                ? .working(recording.metadata.actualStart)
                : .silent(recording.metadata.actualStart)
        }
        return .unknown
    }

    /// Plays a brief tone and taps this process to hear it back.
    ///
    /// Self-contained on purpose: tapping whatever happens to be playing cannot distinguish
    /// "permission denied" from "nothing was making noise".
    public static func probe(duration: TimeInterval = 1.2) async -> Bool {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let tone = makeTone(format: format, seconds: duration, frequency: 440, amplitude: 0.12)
        else { return false }
        engine.connect(player, to: engine.mainMixerNode, format: format)

        // Tap everything, excluding nothing — including ourselves, which is the point.
        let tap: ProcessTap
        do {
            tap = try ProcessTap(scope: .globalExcluding([]), mono: true)
        } catch {
            log.error("probe could not create a tap: \(error.localizedDescription, privacy: .public)")
            return false
        }
        defer { tap.invalidate() }

        let meter = LevelMeter()
        do {
            try tap.start { buffer, _ in meter.accumulate(buffer) }
            try engine.start()
        } catch {
            log.error("probe could not start: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // The completion-handler form, not the async one: `await scheduleBuffer` only returns
        // once the buffer has finished playing, and playback has not started yet at this point,
        // so awaiting it deadlocks.
        let schedule: (AVAudioPCMBuffer) -> Void = { buffer in
            player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }
        schedule(tone)
        player.play()

        try? await Task.sleep(for: .seconds(duration + 0.4))

        player.stop()
        engine.stop()
        tap.stop()

        let rms = meter.rms
        log.notice("system audio probe: rms \(rms) (\(rms.asDecibels) dBFS)")
        return rms >= LevelMeter.silenceThreshold
    }

    private static func makeTone(
        format: AVAudioFormat, seconds: TimeInterval, frequency: Double, amplitude: Float
    ) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = frames

        let step = 2 * Double.pi * frequency / format.sampleRate
        for frame in 0..<Int(frames) {
            // Fade the ends so the tone is a soft blip rather than a click.
            let progress = Double(frame) / Double(frames)
            let envelope = Float(min(1, min(progress, 1 - progress) * 20))
            let sample = Float(sin(step * Double(frame))) * amplitude * envelope
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }
        return buffer
    }
}
