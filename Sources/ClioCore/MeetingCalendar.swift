import AppKit
import EventKit
import Foundation
import Observation

/// A calendar event, as much of it as a meeting note needs.
public struct MeetingEvent: Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var attendees: [MeetingAttendee]
    public var joinURL: URL?
    /// The user said no to it.
    public var declinedByMe: Bool

    public init(id: String, title: String, start: Date, end: Date,
                isAllDay: Bool = false, attendees: [MeetingAttendee] = [],
                joinURL: URL? = nil, declinedByMe: Bool = false) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.attendees = attendees
        self.joinURL = joinURL
        self.declinedByMe = declinedByMe
    }

    /// Something to call, not just a block of time: a link, or other people.
    var isCall: Bool { joinURL != nil || attendees.count > 1 }
}

/// Which event a meeting starting now belongs to, and where its call is.
/// Plain functions over plain values, so they can be tested without a
/// calendar.
public enum MeetingEventMatching {
    /// How early a meeting can be started and still count as its event.
    static let earlyGrace: TimeInterval = 5 * 60

    /// The event being held now: started (or about to), not over, not
    /// all-day, not declined. Of several, calls before blocks of time, then
    /// the most recently started — the one just joined, not the one being
    /// left.
    public static func current(in events: [MeetingEvent], at now: Date = Date()) -> MeetingEvent? {
        events
            .filter { !$0.isAllDay && !$0.declinedByMe
                && $0.start.addingTimeInterval(-earlyGrace) <= now && now < $0.end }
            .max { lhs, rhs in
                if lhs.isCall != rhs.isCall { return !lhs.isCall }
                return lhs.start < rhs.start
            }
    }

    /// Events still to come today, soonest first, for the menu.
    public static func upcoming(in events: [MeetingEvent], at now: Date = Date(),
                                limit: Int = 3) -> [MeetingEvent] {
        Array(events
            .filter { !$0.isAllDay && !$0.declinedByMe && $0.end > now }
            .sorted { $0.start < $1.start }
            .prefix(limit))
    }

    static let conferencingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com",
                                    "teams.live.com", "webex.com", "whereby.com",
                                    "around.co", "facetime.apple.com", "meet.jit.si"]

    /// The call's link: the event's own URL if it is one, else the first
    /// conferencing link in the location, else in the notes. The event's own
    /// URL is often the calendar's page for it, which is no use for joining.
    public static func joinURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isConferencing(url) { return url }
        for text in [location, notes].compactMap({ $0 }) {
            if let found = firstConferencingURL(in: text) { return found }
        }
        return nil
    }

    static func isConferencing(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return conferencingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func firstConferencingURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first(where: isConferencing)
    }
}

/// The user's calendars, through EventKit: whatever macOS Calendar shows —
/// iCloud, Google, Exchange — with one permission and nothing to sign in to.
///
/// Read only, and only when asked: access is requested the first time a
/// meeting is started, not at launch, since dictation never needs it.
@MainActor
@Observable
public final class MeetingCalendar {
    public enum Access: Equatable, Sendable {
        case notDetermined
        case granted
        case denied
    }

    public private(set) var access: Access
    /// Today's events. Refreshed when the calendar changes and whenever
    /// `refresh` is called.
    public private(set) var events: [MeetingEvent] = []

    /// Bumped whenever the calendar changes, so a view showing some other
    /// day knows to read it again.
    public private(set) var revision = 0

    private let store: EKEventStore?
    private var simulated: [MeetingEvent] = []
    private var observer: NSObjectProtocol?

    public init() {
        store = EKEventStore()
        access = Self.currentAccess()
        if access == .granted { startObserving() }
        refresh()
    }

    /// For previews and tests: fixed events, no EventKit.
    public init(simulating events: [MeetingEvent], access: Access = .granted) {
        store = nil
        self.access = access
        self.simulated = events
        self.events = events.filter { Calendar.current.isDateInToday($0.start) }
    }

    /// Any day's events, read now — the day browser's, which is not always
    /// today. Empty without access.
    public func events(on day: Date) -> [MeetingEvent] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        guard let store else {
            return simulated.filter { $0.start < end && $0.end > start }
                .sorted { $0.start < $1.start }
        }
        guard Self.currentAccess() == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map(Self.meetingEvent).sorted { $0.start < $1.start }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public func requestAccess() async {
        guard let store, access == .notDetermined else { return }
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        access = granted ? .granted : .denied
        if granted {
            startObserving()
            refresh()
        }
    }

    public func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    public var current: MeetingEvent? { MeetingEventMatching.current(in: events) }
    public var upcoming: [MeetingEvent] { MeetingEventMatching.upcoming(in: events) }

    public func refresh() {
        guard let store else { return }
        access = Self.currentAccess()
        guard access == .granted else {
            events = []
            return
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        events = store.events(matching: predicate).map(Self.meetingEvent)
        revision += 1
    }

    private func startObserving() {
        guard observer == nil, let store else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private static func meetingEvent(_ event: EKEvent) -> MeetingEvent {
        let participants = event.attendees ?? []
        let attendees = participants.compactMap { participant -> MeetingAttendee? in
            let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = participant.url.absoluteString
                .replacingOccurrences(of: "mailto:", with: "")
            let shown = (name?.isEmpty == false ? name : nil)
                ?? email.components(separatedBy: "@").first
            guard let shown, !shown.isEmpty else { return nil }
            return MeetingAttendee(name: shown,
                                   declined: participant.participantStatus == .declined)
        }
        let declinedByMe = participants.contains {
            $0.isCurrentUser && $0.participantStatus == .declined
        }
        return MeetingEvent(
            id: event.calendarItemIdentifier,
            title: event.title?.isEmpty == false ? event.title! : "Meeting",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            attendees: attendees,
            joinURL: MeetingEventMatching.joinURL(url: event.url,
                                                  location: event.location,
                                                  notes: event.notes),
            declinedByMe: declinedByMe)
    }
}
