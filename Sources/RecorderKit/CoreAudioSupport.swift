import CoreAudio
import Foundation

/// A Core Audio call that returned something other than `noErr`.
///
/// Core Audio reports failures as four-character codes, so the description carries
/// both the numeric status and its FourCC spelling — `'!obj'` is a great deal more
/// searchable than `560947818`.
public struct CoreAudioError: LocalizedError, Sendable {
    public let status: OSStatus
    public let operation: String

    public var errorDescription: String? {
        "\(operation) failed: \(status) (\(Self.fourCC(status)))"
    }

    static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "non-printable" }
        return "'" + String(bytes.map { Character(UnicodeScalar($0)) }) + "'"
    }
}

@discardableResult
public func checkCA(_ operation: String, _ body: () -> OSStatus) throws -> OSStatus {
    let status = body()
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
    return status
}

// MARK: - Property access

public enum CA {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Reads a fixed-size property into a value of type `T`.
    public static func value<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        qualifier: UnsafeRawPointer? = nil,
        qualifierSize: UInt32 = 0,
        as type: T.Type = T.self,
        operation: String = "AudioObjectGetPropertyData"
    ) throws -> T {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { buffer.deallocate() }
        try checkCA(operation) {
            AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, buffer)
        }
        return buffer.pointee
    }

    /// Reads a variable-length property as an array of `T`.
    public static func array<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of type: T.Type = T.self,
        operation: String = "AudioObjectGetPropertyData(array)"
    ) throws -> [T] {
        var address = address
        var byteSize: UInt32 = 0
        try checkCA("AudioObjectGetPropertyDataSize") {
            AudioObjectGetPropertyDataSize(object, &address, 0, nil, &byteSize)
        }
        let count = Int(byteSize) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var result = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        try result.withUnsafeMutableBufferPointer { pointer -> Void in
            try checkCA(operation) {
                AudioObjectGetPropertyData(object, &address, 0, nil, &byteSize, pointer.baseAddress!)
            }
        }
        return result
    }

    public static func string(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        operation: String = "AudioObjectGetPropertyData(string)"
    ) throws -> String {
        let cfString: CFString = try value(object, address, operation: operation)
        return cfString as String
    }

    public static func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(object, &address)
    }

    // MARK: Devices

    /// The built-in output device.
    ///
    /// The aggregate device is deliberately hosted here rather than on the *default*
    /// output: the default changes when headphones connect or a Bluetooth profile
    /// switches, which can tear the aggregate down mid-recording (plan.md §6.3).
    public static func builtInOutputDeviceUID() throws -> String {
        let devices = try array(system, address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
        var fallback: String?
        for device in devices {
            guard let uid = try? string(device, address(kAudioDevicePropertyDeviceUID)) else { continue }
            guard (try? outputChannelCount(device)) ?? 0 > 0 else { continue }
            let transport = (try? value(device, address(kAudioDevicePropertyTransportType), as: UInt32.self)) ?? 0
            if transport == kAudioDeviceTransportTypeBuiltIn { return uid }
            if fallback == nil { fallback = uid }
        }
        if let fallback { return fallback }
        throw CoreAudioError(status: OSStatus(kAudioHardwareBadDeviceError), operation: "builtInOutputDeviceUID")
    }

    public static func defaultOutputDeviceUID() throws -> String {
        let device: AudioObjectID = try value(system, address(kAudioHardwarePropertyDefaultOutputDevice))
        return try string(device, address(kAudioDevicePropertyDeviceUID))
    }

    static func outputChannelCount(_ device: AudioObjectID) throws -> Int {
        var address = self.address(
            kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        try checkCA("AudioObjectGetPropertyDataSize(streamConfiguration)") {
            AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        try checkCA("AudioObjectGetPropertyData(streamConfiguration)") {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw)
        }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
