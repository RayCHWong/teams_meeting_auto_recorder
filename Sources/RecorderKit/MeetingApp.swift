import Foundation

/// A meeting client the recorder knows how to watch, tap and match against the calendar.
///
/// Everything app-specific lives here: which Core Audio process objects belong to the app, and
/// what its join links look like in a calendar event. The rest of the pipeline — monitor, tap,
/// session — only ever sees bundle-id prefixes.
public struct MeetingApp: Sendable, Hashable, CustomStringConvertible {
    /// Short display name: "Teams", "Zoom".
    public let name: String
    /// Matched as `id == prefix || id.hasPrefix(prefix + ".")`.
    public let bundlePrefixes: [String]
    /// Substrings that identify one of this app's meetings in an event's URL, location or notes.
    public let joinURLMarkers: [String]

    public var description: String { name }

    /// The HAL never shows `com.microsoft.teams2` itself — only its children (`.modulehost`,
    /// `.notificationcenter`, `.helper`), so this has to be a prefix match.
    public static let teams = MeetingApp(
        name: "Teams",
        bundlePrefixes: ["com.microsoft.teams2", "com.microsoft.teams"],
        joinURLMarkers: ["teams.microsoft.com/l/meetup-join", "teams.microsoft.com/meet/"])

    /// Zoom does show its main process (`us.zoom.xos`), plus `us.zoom.caphost`. Which one owns
    /// call audio is not something to bet on, so the whole `us.zoom` family is watched, same as
    /// Teams. Join links are `<org>.zoom.us/j/<id>` (also `/my/` and `/w/` for webinars), and
    /// `zoomgov.com` for the government tenant.
    public static let zoom = MeetingApp(
        name: "Zoom",
        bundlePrefixes: ["us.zoom"],
        joinURLMarkers: ["zoom.us/j/", "zoom.us/my/", "zoom.us/w/", "zoomgov.com/j/"])

    /// Every app recorded by default, in the order the UI lists them.
    public static let supported: [MeetingApp] = [.teams, .zoom]

    public static var allBundlePrefixes: [String] { supported.flatMap(\.bundlePrefixes) }

    /// "Teams or Zoom" — for status text that is not about one specific app.
    public static var supportedNames: String {
        supported.map(\.name).joined(separator: " or ")
    }

    public func matches(bundleID: String) -> Bool {
        Self.bundleID(bundleID, matchesAnyOf: bundlePrefixes)
    }

    /// The supported app a process belongs to, if any.
    public static func app(forBundleID bundleID: String) -> MeetingApp? {
        supported.first { $0.matches(bundleID: bundleID) }
    }

    /// The supported app whose join link appears in this text, if any.
    public static func app(forJoinText text: String) -> MeetingApp? {
        supported.first { app in app.joinURLMarkers.contains { text.contains($0) } }
    }

    public static func bundleID(_ bundleID: String, matchesAnyOf prefixes: [String]) -> Bool {
        prefixes.contains { bundleID == $0 || bundleID.hasPrefix($0 + ".") }
    }

    /// The configured prefixes that make up the family `bundleID` belongs to.
    ///
    /// For a supported app that is every configured prefix of that app, so a call in Zoom maps
    /// to the whole `us.zoom` family. For anything else (a testing override such as QuickTime)
    /// it is just the configured prefixes that matched.
    static func family(of bundleID: String, within prefixes: [String]) -> [String] {
        if let app = app(forBundleID: bundleID) {
            let own = prefixes.filter { self.app(forBundleID: $0) == app }
            if !own.isEmpty { return own }
        }
        return prefixes.filter { Self.bundleID(bundleID, matchesAnyOf: [$0]) }
    }

    /// Which of the watched processes to tap, given which of them are using the microphone.
    ///
    /// With Teams and Zoom both running, tapping every watched process would put Teams'
    /// notification chimes into a Zoom recording (and the other way round). So once any process
    /// is pulling from an input device, only the family that owns that call is tapped. With no
    /// input anywhere — a recording started by hand before joining — everything is tapped, as
    /// before, because there is nothing to choose by.
    ///
    /// Returns the indices of the processes to tap and the prefixes to hand the tap for
    /// process restore.
    static func callFamily(
        of processes: [(bundleID: String, isRunningInput: Bool)], within prefixes: [String]
    ) -> (indices: [Int], prefixes: [String]) {
        let live = processes.filter(\.isRunningInput).map(\.bundleID)
        guard !live.isEmpty else { return (Array(processes.indices), prefixes) }
        var familyPrefixes: [String] = []
        for id in live {
            for prefix in family(of: id, within: prefixes) where !familyPrefixes.contains(prefix) {
                familyPrefixes.append(prefix)
            }
        }
        let indices = processes.indices.filter {
            bundleID(processes[$0].bundleID, matchesAnyOf: familyPrefixes)
        }
        return (indices, familyPrefixes)
    }
}
