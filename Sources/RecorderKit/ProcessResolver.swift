import CoreAudio
import Foundation

/// Locates Core Audio *process objects* — the HAL's view of a running app — and reports
/// whether one is currently driving audio input.
///
/// Input specifically, never output: output alone fires on notification sounds, whereas
/// Teams or Zoom pulling from the microphone means a call is genuinely live (plan.md §3, §7).
public enum ProcessResolver {
    /// Every process object the HAL currently knows about.
    public static func allProcessObjects() throws -> [AudioObjectID] {
        try CA.array(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
    }

    public static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var pid = pid
        let object: AudioObjectID = try withUnsafePointer(to: &pid) { pointer in
            try CA.value(
                CA.system,
                CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject),
                qualifier: UnsafeRawPointer(pointer),
                qualifierSize: UInt32(MemoryLayout<pid_t>.size),
                operation: "TranslatePIDToProcessObject")
        }
        guard object != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(status: OSStatus(kAudioHardwareBadObjectError), operation: "processObject(forPID:)")
        }
        return object
    }

    public static func bundleID(of processObject: AudioObjectID) -> String? {
        try? CA.string(processObject, CA.address(kAudioProcessPropertyBundleID))
    }

    public static func pid(of processObject: AudioObjectID) -> pid_t? {
        try? CA.value(processObject, CA.address(kAudioProcessPropertyPID), as: pid_t.self)
    }

    /// Every process object whose bundle id starts with one of `prefixes`.
    ///
    /// Prefix, not equality, and a list rather than one object: Teams has no process object
    /// for `com.microsoft.teams2` itself. The HAL only ever sees its children —
    /// `.modulehost`, `.notificationcenter`, and two or more `.helper` processes — and which
    /// of them owns the call audio is not fixed. Matching one exact bundle id finds nothing
    /// and fails the way everything else in this project fails: quietly.
    public static func processObjects(matchingPrefixes prefixes: [String]) -> [AudioObjectID] {
        guard let objects = try? allProcessObjects() else { return [] }
        return objects.filter { object in
            guard let identifier = bundleID(of: object) else { return false }
            return MeetingApp.bundleID(identifier, matchesAnyOf: prefixes)
        }
    }

    /// The watched processes that belong to the call in progress — see
    /// `MeetingApp.callFamily(of:within:)` — and the prefixes of that family.
    public static func callTargets(matchingPrefixes prefixes: [String]) -> (objects: [AudioObjectID], prefixes: [String]) {
        let objects = processObjects(matchingPrefixes: prefixes)
        let described = objects.map { (bundleID: bundleID(of: $0) ?? "", isRunningInput: isRunningInput($0)) }
        let family = MeetingApp.callFamily(of: described, within: prefixes)
        return (family.indices.map { objects[$0] }, family.prefixes)
    }

    /// The supported app currently using an input device, if any.
    public static func appUsingInput(_ objects: [AudioObjectID]) -> MeetingApp? {
        objects.lazy
            .filter { isRunningInput($0) }
            .compactMap { bundleID(of: $0).flatMap(MeetingApp.app(forBundleID:)) }
            .first
    }

    /// True if *any* of these process objects is pulling from an input device.
    public static func anyRunningInput(_ objects: [AudioObjectID]) -> Bool {
        objects.contains { isRunningInput($0) }
    }

    public static func isRunningInput(_ processObject: AudioObjectID) -> Bool {
        ((try? CA.value(processObject, CA.address(kAudioProcessPropertyIsRunningInput), as: UInt32.self)) ?? 0) != 0
    }

    public static func isRunningOutput(_ processObject: AudioObjectID) -> Bool {
        ((try? CA.value(processObject, CA.address(kAudioProcessPropertyIsRunningOutput), as: UInt32.self)) ?? 0) != 0
    }

    public static func exists(_ processObject: AudioObjectID) -> Bool {
        CA.hasProperty(processObject, CA.address(kAudioProcessPropertyPID))
    }
}
