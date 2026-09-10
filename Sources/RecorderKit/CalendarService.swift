import EventKit
import Foundation
import OSLog

/// Meeting metadata pulled from the calendar at recording start.
public struct MeetingInfo: Sendable, Equatable {
    public var eventIdentifier: String?
    public var title: String
    public var organizer: String?
    public var attendees: [String]
    public var scheduledStart: Date?
    public var scheduledEnd: Date?

    /// What a recording is called when the calendar is not consulted, or nothing matches. A
    /// calendar miss must never prevent or stop a recording — the calendar is decoration on top
    /// of the audio, not a precondition for it (plan.md §8).
    public static let adHoc = MeetingInfo(
        eventIdentifier: nil, title: "ad-hoc meeting", organizer: nil,
        attendees: [], scheduledStart: nil, scheduledEnd: nil)

    public var isAdHoc: Bool { eventIdentifier == nil }

    /// A recording the user named themselves — no calendar involvement.
    public static func named(_ title: String) -> MeetingInfo {
        MeetingInfo(
            eventIdentifier: nil, title: title, organizer: nil,
            attendees: [], scheduledStart: nil, scheduledEnd: nil)
    }
}

/// Looks up the calendar event that a recording should be named after.
public final class CalendarService: @unchecked Sendable {
    private static let log = Logger(subsystem: loggingSubsystem, category: "Calendar")
    private let store = EKEventStore()

    /// A Teams meeting is identified by its join URL appearing anywhere in the event.
    private static let joinURLMarker = "teams.microsoft.com/l/meetup-join"

    public init() {}

    public static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// The best calendar match for a call starting now.
    ///
    /// Returns `.adHoc` rather than nil when nothing matches, and never throws: a calendar
    /// failure must degrade to a differently-named recording, not to no recording.
    public func meeting(at date: Date = Date(), window: TimeInterval = 5 * 60) -> MeetingInfo {
        guard Self.authorizationStatus == .fullAccess else {
            Self.log.notice("no calendar access — recording as ad-hoc")
            return .adHoc
        }
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-window),
            end: date.addingTimeInterval(window),
            calendars: nil)

        // EventKit expands recurrence natively — do not hand-roll RRULE handling (plan.md §8).
        var candidates: [EKEvent] = []
        store.enumerateEvents(matching: predicate) { event, _ in
            if Self.isCandidate(event) { candidates.append(event) }
        }
        guard let best = Self.best(of: candidates, at: date) else {
            Self.log.notice("no matching calendar event — recording as ad-hoc")
            return .adHoc
        }
        return Self.info(from: best)
    }

    /// Yesterday's meetings that *should* have produced a recording — the input to the daily
    /// health check that catches a silently dead detector (plan.md §13, §15.6).
    public func meetings(from start: Date, to end: Date) -> [MeetingInfo] {
        guard Self.authorizationStatus == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var results: [MeetingInfo] = []
        store.enumerateEvents(matching: predicate) { event, _ in
            if Self.isCandidate(event) { results.append(Self.info(from: event)) }
        }
        return results
    }

    /// Every calendar EventKit can see, with its source — the answer to "is the work calendar
    /// actually reachable from this Mac, and which account is it coming from?"
    public func calendarInventory() -> [(title: String, source: String, type: String)] {
        guard Self.authorizationStatus == .fullAccess else { return [] }
        return store.calendars(for: .event).map {
            ($0.title, $0.source?.title ?? "—", String(describing: $0.source?.sourceType.rawValue ?? -1))
        }
    }

    /// All events in a window, matched or not — used to show what EventKit really returns.
    public func rawEvents(from start: Date, to end: Date) -> [(title: String, start: Date, calendar: String, isTeams: Bool)] {
        guard Self.authorizationStatus == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        var results: [(String, Date, String, Bool)] = []
        store.enumerateEvents(matching: predicate) { event, _ in
            results.append((event.title ?? "—", event.startDate, event.calendar?.title ?? "—", Self.containsJoinURL(event)))
        }
        return results
    }

    // MARK: - Matching (plan.md §8)

    static func isCandidate(_ event: EKEvent) -> Bool {
        guard !event.isAllDay else { return false }
        guard participantStatus(event) != .declined else { return false }
        return containsJoinURL(event)
    }

    static func containsJoinURL(_ event: EKEvent) -> Bool {
        let haystacks = [event.url?.absoluteString, event.location, event.notes]
        return haystacks.contains { $0?.contains(joinURLMarker) == true }
    }

    static func participantStatus(_ event: EKEvent) -> EKParticipantStatus {
        event.attendees?.first(where: { $0.isCurrentUser })?.participantStatus ?? .unknown
    }

    static func best(of candidates: [EKEvent], at date: Date) -> EKEvent? {
        candidates.min { lhs, rhs in
            // A meeting that is actually happening beats one that merely starts
            // sooner. Without this the nearest-start rule below is unstable over
            // time: the lookahead window makes the *next* meeting visible five
            // minutes early, and a meeting that began 25 minutes ago always loses
            // to one starting in 5. That is what split a 10:00-11:00 meeting in
            // half at 10:25 on 2026-09-10 — the recording was cut inside its own
            // scheduled hour.
            let lhsRunning = isRunning(lhs, at: date)
            let rhsRunning = isRunning(rhs, at: date)
            if lhsRunning != rhsRunning { return lhsRunning }

            // Accepted beats tentative; then whichever starts nearest to now.
            let lhsRank = rank(participantStatus(lhs))
            let rhsRank = rank(participantStatus(rhs))
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return abs(lhs.startDate.timeIntervalSince(date)) < abs(rhs.startDate.timeIntervalSince(date))
        }
    }

    /// Whether `date` falls inside the event's scheduled window.
    ///
    /// Half-open on purpose: at the instant one meeting ends and the next begins,
    /// only the new one is running, which is exactly the hand-off the split logic
    /// in `Coordinator` is looking for.
    static func isRunning(_ event: EKEvent, at date: Date) -> Bool {
        event.startDate <= date && date < event.endDate
    }

    private static func rank(_ status: EKParticipantStatus) -> Int {
        switch status {
        case .accepted: return 0
        case .tentative: return 1
        default: return 2
        }
    }

    static func info(from event: EKEvent) -> MeetingInfo {
        MeetingInfo(
            eventIdentifier: event.eventIdentifier,
            title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled meeting",
            organizer: displayName(of: event.organizer),
            attendees: (event.attendees ?? []).compactMap(displayName(of:)).sorted(),
            scheduledStart: event.startDate,
            scheduledEnd: event.endDate)
    }

    /// A participant's display name, falling back to their email address.
    ///
    /// The name is what makes a recording recognisable a year later; an address is an identifier
    /// for a mail system, not for a person. Exchange populates the display name for invitees, but
    /// not always — an external guest invited by address alone may have no name at all, and an
    /// address is better than dropping them from the record entirely.
    private static func displayName(of participant: EKParticipant?) -> String? {
        guard let participant else { return nil }
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return name
        }
        let url = participant.url.absoluteString
        return url.hasPrefix("mailto:")
            ? String(url.dropFirst("mailto:".count)).nilIfEmpty
            : url.nilIfEmpty
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
