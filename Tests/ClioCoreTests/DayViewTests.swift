import Testing
import Foundation
@testable import ClioCore

// The day view's decisions, on values: what a day's events are, when the
// card shows itself ahead of a meeting, how overlapping events share the
// timeline, and that its settings survive a file written before them.

private let base = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 24))!

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    base.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
}

private func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> DayEvent {
    DayEvent(id: UUID().uuidString, title: title, start: start, end: end, isAllDay: allDay)
}

@Suite("Day view")
struct DayViewTests {
    @Test("A settings file from before the day view decodes, with it off")
    func oldSettingsDecode() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data(#"{"schemaVersion":1}"#.utf8))
        #expect(settings.dayViewOnWake == false)
        #expect(settings.dayViewBeforeMeetings == false)
        #expect(settings.dayViewLayout == .timeline)
        #expect(settings.dayViewSeconds == 4.5)
        #expect(settings.dayViewPosition == .center)
    }

    @Test("Day view settings round-trip, and a reminder time nobody offers falls back")
    func settingsRoundTrip() throws {
        var settings = Settings()
        settings.dayViewOnWake = true
        settings.dayViewBeforeMeetings = true
        settings.dayViewReminderMinutes = 10
        settings.dayViewPosition = .bottomRight
        settings.dayViewCountdown = .border
        settings.dayViewLayout = .list
        settings.dayViewSeconds = 0
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        #expect(decoded == settings)
        #expect(decoded.dayPanelOptions == DayPanelOptions(seconds: 0, position: .bottomRight,
                                                           countdownStyle: .border, layout: .list))

        let odd = try JSONDecoder().decode(
            Settings.self, from: Data(#"{"dayViewReminderMinutes":7,"dayViewLayout":"spiral"}"#.utf8))
        #expect(odd.dayViewReminderMinutes == 1)
        #expect(odd.dayViewLayout == .timeline)
    }

    @Test("How long the card stays, in words")
    func durationLabels() {
        #expect(Settings.dayViewLabel(forSeconds: 0) == "Until I close it")
        #expect(Settings.dayViewLabel(forSeconds: 6) == "6 seconds")
        #expect(Settings.dayViewLabel(forSeconds: 4.5).hasSuffix("5 seconds"))
    }

    @Test("All-day events lead, the rest go by start, and a meeting in two calendars is shown once")
    func arranged() {
        let events = [
            event("Design review", at(14), at(15)),
            event("Standup", at(9), at(9, 15)),
            event("  standup ", at(9), at(9, 15)),
            event("Payday", base, at(24), allDay: true),
            event("Standup", at(11), at(11, 15)),
        ]
        #expect(DayEvents.arranged(events).map(\.title)
                == ["Payday", "Standup", "Standup", "Design review"])
    }

    @Test("The first web link in a location, and nothing else")
    func firstLink() {
        #expect(DayEvents.firstLink(in: "Room 3B, or https://example.com/call then mailto:a@b.c")?.host
                == "example.com")
        #expect(DayEvents.firstLink(in: "write to someone@example.com") == nil)
        #expect(DayEvents.firstLink(in: nil) == nil)
    }

    @Test("A reminder is due inside the lead, once, and the next look is at the one after")
    func reminderPlan() {
        let events = [
            event("Past", at(8), at(9)),
            event("Soon", at(10, 1), at(11)),
            event("Also soon", at(10, 1), at(10, 30)),
            event("Later", at(15), at(16)),
            event("Holiday", base, at(24), allDay: true),
        ]
        let now = at(10)
        let plan = DayReminder.plan(events: events, now: now, lead: 120, reminded: [], midnight: at(24))
        #expect(plan.due == [at(10, 1)])
        #expect(plan.next == at(14, 58))

        // Shown for already: nothing due, the same next look.
        let again = DayReminder.plan(events: events, now: now, lead: 120,
                                     reminded: [at(10, 1)], midnight: at(24))
        #expect(again.due.isEmpty)
        #expect(again.next == at(14, 58))
    }

    @Test("With nothing ahead the next look is midnight; tomorrow's early meeting is due tonight")
    func reminderAcrossMidnight() {
        let quiet = DayReminder.plan(events: [event("Past", at(8), at(9))], now: at(10),
                                     lead: 300, reminded: [], midnight: at(24))
        #expect(quiet.due.isEmpty)
        #expect(quiet.next == at(24))

        let early = event("Flight", at(24, 10), at(26))
        let late = DayReminder.plan(events: [early], now: at(23, 45), lead: 1800,
                                    reminded: [], midnight: at(24))
        #expect(late.due == [at(24, 10)])
        #expect(late.next == at(24))
    }

    @Test("Overlapping events share the width; ones that do not overlap keep all of it")
    func columns() {
        let a = event("A", at(9), at(11))
        let b = event("B", at(10), at(12))
        let c = event("C", at(11), at(12))
        let d = event("D", at(13), at(14))
        let placed = Dictionary(uniqueKeysWithValues:
            DayEventColumns.place([d, c, b, a]).map { ($0.event.title, $0) })
        #expect(placed["A"]?.column == 0)
        #expect(placed["B"]?.column == 1)
        // A has ended when C starts, so C takes its column back.
        #expect(placed["C"]?.column == 0)
        #expect(placed["A"]?.columns == 2 && placed["B"]?.columns == 2 && placed["C"]?.columns == 2)
        #expect(placed["D"]?.column == 0 && placed["D"]?.columns == 1)
    }

    @Test("The timeline covers the whole local day")
    func span() {
        let span = DaySpan(day: at(13, 30))
        #expect(span.start == base)
        #expect(span.hours == Int((span.end.timeIntervalSince(base) / 3600).rounded(.up)))
        #expect(span.hoursIn(at(13, 30)) == 13.5)
        #expect(span.contains(at(23, 59)) && !span.contains(at(25)))
    }

    @Test("A sample day has what was asked for, and an empty one nothing")
    func sampleDay() {
        let events = SampleDay.events(timed: 12, allDay: 3, on: at(13))
        #expect(events.filter(\.isAllDay).count == 3)
        #expect(events.filter { !$0.isAllDay }.count == 12)
        #expect(events.filter { !$0.isAllDay }.allSatisfy { $0.start >= at(7) && $0.start < at(22) })
        #expect(Set(events.map(\.id)).count == 15)
        #expect(SampleDay.events(timed: 0, allDay: 0, on: at(13)).isEmpty)
    }

    @Test("A simulated calendar's day leaves out what was declined")
    @MainActor
    func simulatedDay() {
        let calendar = MeetingCalendar(simulating: [
            MeetingEvent(id: "1", title: "Sync", start: at(10), end: at(11)),
            MeetingEvent(id: "2", title: "Skipped", start: at(12), end: at(13), declinedByMe: true),
            MeetingEvent(id: "3", title: "Tomorrow", start: at(34), end: at(35)),
        ])
        #expect(calendar.dayEvents(on: at(9)).map(\.title) == ["Sync"])
    }
}
