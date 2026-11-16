import Testing
@testable import RecorderKit

@Suite struct MeetingAppTests {
    // Bundle ids seen in the HAL on a real machine (TapSpike list, 2026-11-14).
    static let teamsIDs = [
        "com.microsoft.teams2.modulehost", "com.microsoft.teams2.helper",
        "com.microsoft.teams2.notificationcenter",
    ]
    static let zoomIDs = ["us.zoom.xos", "us.zoom.caphost"]

    @Test func identifiesAppsByBundleID() {
        for id in Self.teamsIDs { #expect(MeetingApp.app(forBundleID: id) == .teams) }
        for id in Self.zoomIDs { #expect(MeetingApp.app(forBundleID: id) == .zoom) }
        #expect(MeetingApp.app(forBundleID: "com.apple.Safari") == nil)
        // A prefix must end on a dot boundary, not mid-word.
        #expect(MeetingApp.app(forBundleID: "us.zoomer.app") == nil)
        #expect(MeetingApp.app(forBundleID: "com.microsoft.teamsfoo") == nil)
    }

    @Test func defaultPrefixesCoverBothApps() {
        let prefixes = MeetingApp.allBundlePrefixes
        for id in Self.teamsIDs + Self.zoomIDs {
            #expect(MeetingApp.bundleID(id, matchesAnyOf: prefixes))
        }
        #expect(MeetingApp.supportedNames == "Teams or Zoom")
    }

    @Test func tapsOnlyZoomWhenZoomHasTheMic() {
        let processes: [(bundleID: String, isRunningInput: Bool)] = [
            ("com.microsoft.teams2.helper", false),
            ("com.microsoft.teams2.modulehost", false),
            ("us.zoom.xos", true),
            ("us.zoom.caphost", false),
        ]
        let result = MeetingApp.callFamily(of: processes, within: MeetingApp.allBundlePrefixes)
        #expect(result.indices == [2, 3])
        #expect(result.prefixes == ["us.zoom"])
    }

    @Test func tapsOnlyTeamsWhenTeamsHasTheMic() {
        let processes: [(bundleID: String, isRunningInput: Bool)] = [
            ("us.zoom.xos", false),
            ("com.microsoft.teams2.helper", false),
            ("com.microsoft.teams2.modulehost", true),
        ]
        let result = MeetingApp.callFamily(of: processes, within: MeetingApp.allBundlePrefixes)
        #expect(result.indices == [1, 2])
        #expect(result.prefixes == ["com.microsoft.teams2", "com.microsoft.teams"])
    }

    @Test func tapsEverythingWhenNobodyHasTheMic() {
        let processes: [(bundleID: String, isRunningInput: Bool)] = [
            ("us.zoom.xos", false), ("com.microsoft.teams2.helper", false),
        ]
        let result = MeetingApp.callFamily(of: processes, within: MeetingApp.allBundlePrefixes)
        #expect(result.indices == [0, 1])
        #expect(result.prefixes == MeetingApp.allBundlePrefixes)
    }

    @Test func tapsBothWhenBothHaveTheMic() {
        let processes: [(bundleID: String, isRunningInput: Bool)] = [
            ("us.zoom.xos", true), ("com.microsoft.teams2.helper", true),
        ]
        let result = MeetingApp.callFamily(of: processes, within: MeetingApp.allBundlePrefixes)
        #expect(result.indices == [0, 1])
    }

    @Test func testingOverrideStillWorks() {
        // `defaults write … targetBundlePrefixes -array com.apple.QuickTimePlayerX`
        let processes: [(bundleID: String, isRunningInput: Bool)] = [("com.apple.QuickTimePlayerX", true)]
        let result = MeetingApp.callFamily(of: processes, within: ["com.apple.QuickTimePlayerX"])
        #expect(result.indices == [0])
        #expect(result.prefixes == ["com.apple.QuickTimePlayerX"])
    }

    @Test func zoomOnlyOverrideDoesNotPullInTeams() {
        let processes: [(bundleID: String, isRunningInput: Bool)] = [("us.zoom.xos", true)]
        let result = MeetingApp.callFamily(of: processes, within: ["us.zoom"])
        #expect(result.prefixes == ["us.zoom"])
    }
}

@Suite struct CalendarJoinLinkTests {
    @Test func recognisesTeamsLinks() {
        #expect(CalendarService.joinApp(
            url: nil, location: "Microsoft Teams Meeting",
            notes: "Join: https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc") == .teams)
        #expect(CalendarService.joinApp(
            url: "https://teams.microsoft.com/meet/123456?p=abc", location: nil, notes: nil) == .teams)
    }

    @Test func recognisesZoomLinks() {
        #expect(CalendarService.joinApp(
            url: nil, location: "https://utoronto.zoom.us/j/81234567890?pwd=x", notes: nil) == .zoom)
        #expect(CalendarService.joinApp(
            url: "https://zoom.us/my/someroom", location: nil, notes: nil) == .zoom)
        #expect(CalendarService.joinApp(
            url: nil, location: nil, notes: "Webinar: https://example.zoom.us/w/123") == .zoom)
        #expect(CalendarService.joinApp(
            url: nil, location: nil, notes: "https://agency.zoomgov.com/j/1612345678") == .zoom)
    }

    @Test func ignoresNonMeetingLinks() {
        #expect(CalendarService.joinApp(
            url: "https://zoom.us/signin", location: "Room 101", notes: "See https://example.com") == nil)
    }

    @Test func urlFieldWinsOverNotes() {
        // A Zoom meeting whose notes mention a Teams fallback is a Zoom meeting.
        #expect(CalendarService.joinApp(
            url: "https://utoronto.zoom.us/j/1", location: nil,
            notes: "Backup: https://teams.microsoft.com/l/meetup-join/x") == .zoom)
    }
}
