import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// Captures the audio of another process via a Core Audio process tap.
///
/// The shape of this is fixed by the HAL: a tap on its own delivers nothing. It has to be
/// installed into an aggregate device, and you then read the aggregate's *input* stream
/// (plan.md §6.2). Two ordering rules from §6.3 are load-bearing and are enforced by the
/// caller, not here:
///
///   1. The microphone `AVCaptureSession` must already be running before the aggregate is
///      created, or a Bluetooth A2DP→HFP switch happens underneath it and the mic goes silent.
///   2. The aggregate is hosted on the *built-in* output, never the default output.
public final class ProcessTap: @unchecked Sendable {
    public enum Scope: Sendable {
        /// Tap exactly these process objects.
        case processes([AudioObjectID])
        /// Tap everything except these process objects (used as the §6.2 fallback).
        case globalExcluding([AudioObjectID])
    }

    private static let log = Logger(subsystem: loggingSubsystem, category: "ProcessTap")

    public private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false
    private let ioQueue = DispatchQueue(label: "com.raywong.meetingrecorder.tap-io", qos: .userInitiated)

    /// The format the tap actually delivers. Not assumed — read back from the tap object.
    public private(set) var format: AVAudioFormat

    public let scope: Scope
    private let tapUUID = UUID()

    public init(scope: Scope, mono: Bool = false, restoreBundleIDs: [String] = []) throws {
        self.scope = scope

        let description: CATapDescription
        switch scope {
        case .processes(let objects):
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        case .globalExcluding(let objects):
            description = CATapDescription(monoGlobalTapButExcludeProcesses: objects)
        }
        description.name = "Teams Meeting Auto-Recorder"
        description.uuid = tapUUID
        description.muteBehavior = .unmuted   // never mute Teams for the user
        description.isPrivate = true          // invisible in Audio MIDI Setup
        description.isMono = mono

        // macOS 26 can re-attach the tap by bundle id when the app restarts, which covers
        // "Teams restarts mid-call" (plan.md §9.4) without re-resolving the process object.
        if #available(macOS 26.0, *), !restoreBundleIDs.isEmpty {
            description.bundleIDs = restoreBundleIDs
            description.isProcessRestoreEnabled = true
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        try checkCA("AudioHardwareCreateProcessTap") {
            AudioHardwareCreateProcessTap(description, &tap)
        }
        tapID = tap

        var streamDescription = try CA.value(
            tapID, CA.address(kAudioTapPropertyFormat),
            as: AudioStreamBasicDescription.self, operation: "kAudioTapPropertyFormat")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError(status: OSStatus(kAudioFormatUnsupportedDataFormatError), operation: "AVAudioFormat(tap)")
        }
        self.format = format

        let hostUID = try CA.builtInOutputDeviceUID()
        let aggregateUID = "com.raywong.meetingrecorder.aggregate.\(tapUUID.uuidString)"
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Meeting Recorder Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: hostUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: hostUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tapUUID.uuidString,
            ]],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        do {
            try checkCA("AudioHardwareCreateAggregateDevice") {
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
            }
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw error
        }
        aggregateID = aggregate

        Self.log.info("tap \(self.tapID) + aggregate \(self.aggregateID) on \(hostUID, privacy: .public), format \(format, privacy: .public)")
    }

    /// Installs the IOProc and starts the device.
    ///
    /// This is where the TCC prompt fires — not on tap creation, not on aggregate creation
    /// (plan.md §6.4). Every call in the chain returns `noErr` whether or not permission was
    /// granted, so the only evidence of success is non-zero samples downstream.
    public func start(handler: @escaping @Sendable (AVAudioPCMBuffer, AudioTimeStamp) -> Void) throws {
        guard !isRunning else { return }
        let format = self.format

        var procID: AudioDeviceIOProcID?
        try checkCA("AudioDeviceCreateIOProcIDWithBlock") {
            AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inputData, inputTime, _, _ in
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData) else { return }
                handler(buffer, inputTime.pointee)
            }
        }
        ioProcID = procID

        do {
            try checkCA("AudioDeviceStart") { AudioDeviceStart(aggregateID, procID) }
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            ioProcID = nil
            throw error
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning, let ioProcID else { return }
        AudioDeviceStop(aggregateID, ioProcID)
        AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        self.ioProcID = nil
        isRunning = false
    }

    public func invalidate() {
        stop()
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }
}
