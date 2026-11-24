import Foundation

// The day view: a small card with today's events, shown when the Mac wakes,
// before a meeting, or when asked for. This file is what it shows and when,
// as values — the card itself is ClioUI's `DayPanelController`.

/// Where the day panel appears.
public enum DayPanelPosition: String, Codable, Sendable, CaseIterable, Identifiable {
    case center, topLeft, topRight, bottomLeft, bottomRight

    public var id: Self { self }

    public var title: String {
        switch self {
        case .center: "Center"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}

/// How the panel shows the time it has left.
public enum DayCountdownStyle: String, Codable, Sendable, CaseIterable, Identifiable {
    /// A small ring opposite the date.
    case ring
    /// A line round the panel's edge.
    case border

    public var id: Self { self }

    public var title: String {
        switch self {
        case .ring: "Ring"
        case .border: "Border"
        }
    }
}

/// How the day's events are laid out.
public enum DayLayout: String, Codable, Sendable, CaseIterable, Identifiable {
    /// One row per event.
    case list
    /// Hours down the side, events sized by their length.
    case timeline

    public var id: Self { self }

    public var title: String {
        switch self {
        case .list: "List"
        case .timeline: "Timeline"
        }
    }
}

/// Everything about how the panel looks, as one value for the panel to take.
public struct DayPanelOptions: Sendable, Equatable {
    /// How long it stays up. Zero: until it is closed.
    public var seconds: TimeInterval
    public var position: DayPanelPosition
    public var countdownStyle: DayCountdownStyle
    public var layout: DayLayout

    public init(seconds: TimeInterval, position: DayPanelPosition,
                countdownStyle: DayCountdownStyle, layout: DayLayout) {
        self.seconds = seconds
        self.position = position
        self.countdownStyle = countdownStyle
        self.layout = layout
    }
}

extension Settings {
    /// The choices Settings offers for how long the panel stays, in order;
    /// 0 is "until I close it".
    public static let dayViewDurations: [Double] = [3, 4.5, 6, 8, 10, 15, 30, 0]
    /// Minutes before a meeting the panel can be shown.
    public static let dayViewReminderChoices = [1, 2, 5, 10, 15, 30]

    public static func dayViewLabel(forSeconds seconds: Double) -> String {
        guard seconds > 0 else { return "Until I close it" }
        return seconds.rounded() == seconds
            ? "\(Int(seconds)) seconds"
            : "\(seconds.formatted(.number.precision(.fractionLength(1)))) seconds"
    }

    public var dayPanelOptions: DayPanelOptions {
        DayPanelOptions(seconds: dayViewSeconds, position: dayViewPosition,
                        countdownStyle: dayViewCountdown, layout: dayViewLayout)
    }
}

/// One event as the day panel draws it — copied out of EventKit so the view
/// never holds an EKEvent.
public struct DayEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let location: String?
    public var url: URL?
    /// The calendar's colour; nil is drawn in the accent colour.
    public let color: CalendarColor?

    public init(id: String, title: String, start: Date, end: Date, isAllDay: Bool,
                location: String? = nil, url: URL? = nil, color: CalendarColor? = nil) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.url = url
        self.color = color
    }
}

/// A day's events as the panel wants them, from however the calendar gave
/// them.
public enum DayEvents {
    /// All-day ones first, then by start, then by title — and the same
    /// meeting once: it often sits in two calendars, a work account and a
    /// personal one it was forwarded to. Same title, same times: once.
    public static func arranged(_ events: [DayEvent]) -> [DayEvent] {
        var seen = Set<String>()
        return events
            .filter { event in
                let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let key = "\(title)|\(event.isAllDay)|\(event.start.timeIntervalSince1970)|\(event.end.timeIntervalSince1970)"
                return seen.insert(key).inserted
            }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return lhs.isAllDay }
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.title < rhs.title
            }
    }

    /// The first web link in a location or an event's notes.
    public static func firstLink(in text: String?) -> URL? {
        guard let text,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range).compactMap(\.url).first {
            ["https", "http"].contains($0.scheme?.lowercased() ?? "")
        }
    }
}

/// When the panel shows itself ahead of a meeting.
public enum DayReminder {
    public struct Plan: Equatable, Sendable {
        /// The starts a reminder is due for now: show the panel, once, and
        /// remember them all.
        public var due: [Date]
        /// When to look again: the next reminder, or `midnight`, whichever
        /// comes first. Tomorrow's early meetings can have one due tonight.
        public var next: Date
    }

    /// - Parameters:
    ///   - events: today's and tomorrow's.
    ///   - lead: how long before a start the panel shows.
    ///   - reminded: the starts already shown for.
    ///   - midnight: the end of today.
    public static func plan(events: [DayEvent], now: Date, lead: TimeInterval,
                            reminded: Set<Date>, midnight: Date) -> Plan {
        let starts = Set(events.filter { !$0.isAllDay && $0.start > now }.map(\.start))
            .subtracting(reminded).sorted()
        let due = Array(starts.prefix { $0.timeIntervalSince(now) <= lead })
        let next = starts.dropFirst(due.count).first?.addingTimeInterval(-lead) ?? midnight
        return Plan(due: due, next: min(next, midnight))
    }
}

/// The hours the timeline covers: the whole local day.
public struct DaySpan: Sendable {
    public let start: Date
    public let end: Date
    public let hours: Int

    public init(day: Date, calendar: Calendar = .current) {
        start = calendar.startOfDay(for: day)
        end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        hours = Int((end.timeIntervalSince(start) / 3600).rounded(.up))
    }

    public func contains(_ date: Date) -> Bool { date >= start && date <= end }

    /// How far down the timeline a moment is, in hours.
    public func hoursIn(_ date: Date) -> Double {
        date.timeIntervalSince(start) / 3600
    }

    /// "08", "9 AM" — the hour alone, as the Mac writes it.
    public func hourLabel(_ index: Int) -> String {
        let date = start.addingTimeInterval(TimeInterval(index) * 3600)
        if Calendar.current.component(.hour, from: date) == 0, index > 0 { return "24" }
        return date.formatted(.dateTime.hour())
    }
}

/// Events that overlap share the width, side by side, the way Calendar
/// does: each takes the first column free when it starts, and every event in
/// a run of overlaps is as narrow as the widest moment in that run needs.
public enum DayEventColumns {
    public struct Placed: Sendable {
        public let event: DayEvent
        public let column: Int
        public var columns: Int
    }

    public static func place(_ events: [DayEvent]) -> [Placed] {
        let sorted = events.sorted {
            $0.start != $1.start ? $0.start < $1.start : $0.end > $1.end
        }
        var placed: [Placed] = []
        var cluster: [Placed] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func closeCluster() {
            let width = columnEnds.count
            placed += cluster.map { var p = $0; p.columns = width; return p }
            cluster = []
            columnEnds = []
        }

        for event in sorted {
            if event.start >= clusterEnd { closeCluster() }
            let column = columnEnds.firstIndex { $0 <= event.start } ?? columnEnds.count
            if column == columnEnds.count {
                columnEnds.append(event.end)
            } else {
                columnEnds[column] = event.end
            }
            cluster.append(Placed(event: event, column: column, columns: 1))
            clusterEnd = max(clusterEnd, event.end)
        }
        closeCluster()
        return placed
    }
}

/// Made-up days for the Day View tab's Developer section: as many events as
/// asked for, so a long list, wrapping all-day chips or the empty state can
/// be seen without filling a real calendar.
public enum SampleDay {
    public static func events(timed: Int, allDay: Int, on day: Date) -> [DayEvent] {
        let start = Calendar.current.startOfDay(for: day)

        let allDayEvents = (0..<max(allDay, 0)).map { index in
            DayEvent(id: "sample-allday-\(index)",
                     title: allDayTitles[index % allDayTitles.count],
                     start: start,
                     end: start.addingTimeInterval(86_400),
                     isAllDay: true,
                     color: colors[(index + 2) % colors.count])
        }

        // Spread from 7:00 to 22:00, so wherever "now" is it lands among
        // them: some past, one usually in progress, some ahead.
        let first = start.addingTimeInterval(7 * 3600)
        let span: TimeInterval = 15 * 3600
        let step = timed > 0 ? span / Double(timed) : 0
        let durations: [TimeInterval] = [30, 45, 60, 90, 25].map { $0 * 60 }
        let timedEvents = (0..<max(timed, 0)).map { index in
            let begins = first.addingTimeInterval(step * Double(index))
            return DayEvent(id: "sample-timed-\(index)",
                            title: titles[index % titles.count],
                            start: begins,
                            end: begins.addingTimeInterval(durations[index % durations.count]),
                            isAllDay: false,
                            location: index % 3 == 1 ? locations[index % locations.count] : nil,
                            url: links[index % titles.count],
                            color: colors[index % colors.count])
        }

        return allDayEvents + timedEvents
    }

    private static let titles = [
        "Standup", "Design review", "Lunch with Ola", "1:1 with Marcin",
        "Quarterly planning — roadmap, hiring and the budget for next year",
        "Focus time", "Dentist", "Coffee chat", "Release sync", "Gym",
        "Interview: Senior iOS Engineer", "Pick up groceries", "Call mum", "Dinner",
    ]

    private static let links = [
        0: URL(string: "https://example.com/standup")!,
        1: URL(string: "https://example.com/design-review")!,
    ]

    private static let allDayTitles = [
        "Office closed", "Ola's birthday", "Sprint 42",
        "Conference: Swift Heroes — Day 1 of 3, Turin", "Payday", "Trash day",
        "Release week", "Out of office",
    ]

    private static let locations = ["Zoom", "Room 3B", "Warszawa", "Google Meet"]

    /// The system's blue, orange, green, purple, pink, teal, red, yellow.
    private static let colors: [CalendarColor] = [
        CalendarColor(red: 0.00, green: 0.48, blue: 1.00),
        CalendarColor(red: 1.00, green: 0.58, blue: 0.00),
        CalendarColor(red: 0.20, green: 0.78, blue: 0.35),
        CalendarColor(red: 0.69, green: 0.32, blue: 0.87),
        CalendarColor(red: 1.00, green: 0.18, blue: 0.33),
        CalendarColor(red: 0.19, green: 0.69, blue: 0.78),
        CalendarColor(red: 1.00, green: 0.23, blue: 0.19),
        CalendarColor(red: 1.00, green: 0.80, blue: 0.00),
    ]
}
