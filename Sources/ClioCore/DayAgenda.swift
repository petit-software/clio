import Foundation

/// One day, as the library's sidebar shows it: the calendar's events, each
/// with the notes Clio took for it, then the day's other notes, then its
/// dictations. Plain values in, plain values out, so it can be tested
/// without a calendar or a folder.
public struct DayAgenda: Equatable, Sendable {

    /// A calendar event, and the notes taken for it if there are any.
    public struct Event: Equatable, Sendable, Identifiable {
        public var event: MeetingEvent
        public var notes: MeetingFile?
        public var id: String { event.id }
    }

    public var day: Date
    public var events: [Event]
    /// The day's notes that belong to no event on it.
    public var otherNotes: [MeetingFile]
    public var dictations: [TranscriptEntry]

    public var isEmpty: Bool { events.isEmpty && otherNotes.isEmpty && dictations.isEmpty }

    /// How early notes can start and still be the event's: someone joining
    /// a few minutes before the hour.
    static let earlyStart: TimeInterval = 10 * 60

    public static func make(day: Date,
                            events: [MeetingEvent],
                            files: [MeetingFile],
                            dictations: [TranscriptEntry],
                            calendar: Calendar = .current) -> DayAgenda {
        let todays = files
            .filter { calendar.isDate($0.start, inSameDayAs: day) }
            .sorted { $0.start < $1.start }
        let shown = events
            .filter { !$0.isAllDay && !$0.declinedByMe }
            .sorted { $0.start < $1.start }

        var unclaimed = todays
        var items: [Event] = []
        var linked: [String: MeetingFile] = [:]

        /// How far notes began from an event: nothing while it was on.
        func distance(_ file: MeetingFile, _ event: MeetingEvent) -> TimeInterval {
            if file.start < event.start { return event.start.timeIntervalSince(file.start) }
            if file.start > event.end { return file.start.timeIntervalSince(event.end) }
            return 0
        }
        /// Of the notes nobody has yet that pass, the ones begun nearest.
        func nearest(to event: MeetingEvent, where passes: (MeetingFile) -> Bool) -> Int? {
            unclaimed.indices.filter { passes(unclaimed[$0]) }
                .min { distance(unclaimed[$0], event) < distance(unclaimed[$1], event) }
        }

        // 1. Notes that say which event they were taken for, or were given
        // to. An id is shared by a repeating event's occurrences, so of two
        // on one day each takes the notes begun nearest it.
        for event in shown {
            if let index = nearest(to: event, where: { $0.eventID == event.id }) {
                linked[event.id] = unclaimed.remove(at: index)
            }
        }
        // 2. The same, by the name the calendar's server gives the event:
        // a sync from scratch hands every event a new id, and notes that
        // carried the old one were under nothing at all.
        for event in shown where linked[event.id] == nil {
            guard let key = event.externalID else { continue }
            if let index = nearest(to: event, where: { $0.eventKey == key }) {
                linked[event.id] = unclaimed.remove(at: index)
            }
        }
        // 3. Notes called what an event on the day is called — whenever
        // they began, and whatever event they once named: the nearest pair
        // first, so of two events with one name each gets its own.
        var pairs: [(file: URL, event: MeetingEvent, apart: TimeInterval)] = []
        for event in shown where linked[event.id] == nil {
            for file in unclaimed
            where file.title.localizedCaseInsensitiveCompare(event.title) == .orderedSame {
                pairs.append((file.url, event, distance(file, event)))
            }
        }
        for pair in pairs.sorted(by: { $0.apart < $1.apart }) where linked[pair.event.id] == nil {
            if let index = unclaimed.firstIndex(where: { $0.url == pair.file }) {
                linked[pair.event.id] = unclaimed.remove(at: index)
            }
        }
        // 4. By time alone: notes that began while the event was on, or
        // just before it.
        for event in shown where linked[event.id] == nil {
            let during = unclaimed.firstIndex { file in
                file.start >= event.start.addingTimeInterval(-earlyStart) && file.start < event.end
            }
            if let during { linked[event.id] = unclaimed.remove(at: during) }
        }
        for event in shown {
            items.append(Event(event: event, notes: linked[event.id]))
        }

        return DayAgenda(
            day: calendar.startOfDay(for: day),
            events: items,
            otherNotes: unclaimed.sorted { $0.start > $1.start },
            dictations: dictations
                .filter { calendar.isDate($0.date, inSameDayAs: day) }
                .sorted { $0.date > $1.date })
    }

    /// The days around `day`, one step at a time: the day browser's ‹ and ›.
    public static func step(_ day: Date, by days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: day))
            ?? calendar.startOfDay(for: day)
    }
}
