import AVFoundation
import Foundation
import OSLog

/// Captures the local microphone.
///
/// `AVCaptureSession`, not `AVAudioEngine.installTap`: `installTap` has been reported not to
/// fire with Bluetooth input on macOS 26, and AirPods are the likely input here (plan.md §3).
public final class MicCapture: NSObject, @unchecked Sendable {
    private static let log = Logger(subsystem: loggingSubsystem, category: "MicCapture")

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let sampleQueue = DispatchQueue(label: "com.raywong.meetingrecorder.mic", qos: .userInitiated)
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    public private(set) var format: AVAudioFormat?
    public private(set) var deviceName: String?

    public override init() { super.init() }

    public static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Starts the session and blocks until the first sample buffer arrives (or `timeout`
    /// elapses), so the caller knows the real format before creating the file.
    ///
    /// Must be called *before* the aggregate device is created: opening the mic forces a
    /// Bluetooth A2DP→HFP profile negotiation, and if the aggregate already exists it breaks
    /// underneath it and the mic channel fails silently (plan.md §6.3).
    public func start(timeout: TimeInterval = 3.0) throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noAudioInputDevice
        }
        deviceName = device.localizedName

        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw RecorderError.noAudioInputDevice
        }
        session.addInput(input)
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw RecorderError.noAudioInputDevice
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()

        let deadline = Date().addingTimeInterval(timeout)
        while format == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Self.log.info("mic session started on \(self.deviceName ?? "?", privacy: .public), format \(String(describing: self.format), privacy: .public)")
    }

    /// Installs the buffer handler. Separate from `start` so the session can be brought up
    /// early (§6.3) and only wired to a file once recording actually begins.
    public func setHandler(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    public func stop() {
        setHandler(nil)
        if session.isRunning { session.stopRunning() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
    }

    public var isRunning: Bool { session.isRunning }
}

extension MicCapture: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
        else { return }

        if format == nil {
            var asbd = streamDescription.pointee
            format = AVAudioFormat(streamDescription: &asbd)
        }
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler, let format else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else { return }
        handler(buffer)
    }
}
