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
        // Notes that say which event they were taken for, first — then, for
        // older notes and ones started from the menu, by time: notes that
        // began while the event was on, or just before it, the same title
        // first.
        var linked: [String: MeetingFile] = [:]
        for event in shown {
            if let index = unclaimed.firstIndex(where: { $0.eventID == event.id }) {
                linked[event.id] = unclaimed.remove(at: index)
            }
        }
        for event in shown where linked[event.id] == nil {
            let during = unclaimed.indices.filter { index in
                let file = unclaimed[index]
                return file.eventID == nil
                    && file.start >= event.start.addingTimeInterval(-earlyStart)
                    && file.start < event.end
            }
            let titled = during.first {
                unclaimed[$0].title.localizedCaseInsensitiveCompare(event.title) == .orderedSame
            }
            if let index = titled ?? during.first {
                linked[event.id] = unclaimed.remove(at: index)
            }
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
