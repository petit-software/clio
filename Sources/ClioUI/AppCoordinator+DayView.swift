import AppKit
import ClioCore

/// What the Day View tab's Developer section can pretend, in builds that
/// are not releases: made-up events in place of the calendar, and a time of
/// day other than now. Never written, so a relaunch is always back to the
/// real day.
public struct DayViewDeveloper: Equatable, Sendable {
    public var useSampleEvents = false
    public var sampleTimedCount = 12
    public var sampleAllDayCount = 3
    /// Pretend it is this time of day, today: for the now line, the dimmed
    /// past and the Now badge.
    public var overridesTime = false
    public var overrideTime = Calendar.current.date(bySettingHour: 13, minute: 0, second: 0,
                                                    of: Date()) ?? Date()

    public init() {}
}

/// The day view: a card with the day's events, when the Mac wakes, shortly
/// before a meeting, and from the menu — Settings ▸ Day View says which.
/// The card is `DayPanelController`; when and what is here.
extension AppCoordinator {

    /// From `start`. Follows the calendar and the Mac waking, and shows the
    /// day once at launch where Settings asks for it.
    func startDayView() {
        calendar.onChange = { [weak self] in
            self?.refreshVisibleDay()
            self?.scheduleDayReminder()
        }
        wakeObserver = WakeObserver { [weak self] in
            self?.calendar.refresh()
            self?.showDayAutomatically()
            self?.scheduleDayReminder()
        }
        scheduleDayReminder()
        // A beat after launch: at login the menu bar and the desktop are
        // still settling, and a panel placed now can land on a screen whose
        // visible frame is about to change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showDayAutomatically()
        }
    }

    func stopDayView() {
        dayReminderTask?.cancel()
        wakeObserver = nil
    }

    private var usesSampleDay: Bool {
        Self.isDeveloperBuild && dayDeveloper.useSampleEvents
    }

    /// Whether there is a day to show: the calendar's, or a made-up one.
    public var canShowDay: Bool { usesSampleDay || calendar.access == .granted }

    public var isDayVisible: Bool { dayPanel?.isVisible ?? false }

    /// From the menu and Settings' Preview. Without the calendar there is
    /// no day: it is asked for where it can be, and System Settings opened
    /// where it was refused.
    public func showDay() {
        guard canShowDay else {
            switch calendar.access {
            case .notDetermined:
                Task { @MainActor in
                    NSApp.activate(ignoringOtherApps: true)
                    await calendar.requestAccess()
                    if calendar.access == .granted { showDay() }
                }
            default:
                calendar.openPrivacySettings()
            }
            return
        }
        let now = dayClock
        panel().show(day: now, events: dayEvents(on: now),
                     options: settingsStore.settings.dayPanelOptions)
    }

    /// A second request puts it away.
    public func toggleDay() {
        if isDayVisible {
            dayPanel?.dismiss()
        } else {
            showDay()
        }
    }

    /// Re-reads the events into a panel already on screen — a calendar
    /// change, or a setting moved while previewing.
    public func refreshVisibleDay() {
        guard let dayPanel, dayPanel.isVisible, canShowDay else { return }
        let now = dayClock
        dayPanel.update(day: now, events: dayEvents(on: now),
                        options: settingsStore.settings.dayPanelOptions)
    }

    /// At launch and on wake. Both can arrive in bursts — a system wake
    /// reports the screens waking too — so a second request inside half a
    /// minute is the same moment, not a new one.
    func showDayAutomatically() {
        guard settingsStore.settings.dayViewOnWake, calendar.access == .granted else { return }
        if let last = lastAutomaticDay, Date().timeIntervalSince(last) < 30 { return }
        lastAutomaticDay = Date()
        showDay()
    }

    /// Shows the day ahead of the next meeting, and looks again at the
    /// reminder after it or at midnight, whichever comes first. Called
    /// whenever what it depends on changes: the calendar, the settings, a
    /// wake.
    public func scheduleDayReminder() {
        dayReminderTask?.cancel()
        let settings = settingsStore.settings
        guard settings.dayViewBeforeMeetings, calendar.access == .granted else { return }

        let now = Date()
        let local = Calendar.current
        guard let tomorrow = local.dateInterval(of: .day, for: now)?.end else { return }
        dayRemindedStarts = dayRemindedStarts.filter { $0 > now }
        let plan = DayReminder.plan(
            events: calendar.dayEvents(on: now) + calendar.dayEvents(on: tomorrow),
            now: now, lead: TimeInterval(settings.dayViewReminderMinutes * 60),
            reminded: dayRemindedStarts, midnight: tomorrow)

        // A reminder that falls due while the screen is locked is not kept
        // for the unlock: by then the wake shows the day anyway, or the
        // meeting has begun.
        if let first = plan.due.first, !WakeObserver.isScreenLocked {
            dayRemindedStarts.formUnion(plan.due)
            let day = local.isDate(first, inSameDayAs: now) ? now : tomorrow
            panel().show(day: day, events: calendar.dayEvents(on: day),
                         options: settings.dayPanelOptions)
        }
        let delay = max(0.05, plan.next.timeIntervalSinceNow)
        dayReminderTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.scheduleDayReminder()
        }
    }

    /// The day, up for as long as the card for a call that is starting is:
    /// the card says which call, the day behind it says what else there is.
    /// Returns what to do when the card goes — put the day away if this
    /// brought it up, or let its own countdown carry on if it was there
    /// already. Nothing, where there is no day to show.
    func holdDayForCall() -> () -> Void {
        guard canShowDay else { return {} }
        if isDayVisible {
            dayPanel?.hold()
            return { [weak self] in self?.dayPanel?.release() }
        }
        let now = dayClock
        var options = settingsStore.settings.dayPanelOptions
        options.seconds = 0
        let panel = panel()
        panel.show(day: now, events: dayEvents(on: now), options: options)
        panel.hold()
        return { [weak self] in self?.dayPanel?.dismiss() }
    }

    // MARK: What it shows

    private func panel() -> DayPanelController {
        if let dayPanel { return dayPanel }
        let made = DayPanelController()
        dayPanel = made
        return made
    }

    /// The time the panel shows: the real one, or today at the time set in
    /// the Developer section.
    private var dayClock: Date {
        let real = Date()
        guard Self.isDeveloperBuild, dayDeveloper.overridesTime else { return real }
        let calendar = Calendar.current
        let time = calendar.dateComponents([.hour, .minute], from: dayDeveloper.overrideTime)
        return calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0,
                             second: 0, of: real) ?? real
    }

    /// The calendar's, or the made-up ones from the Developer section.
    private func dayEvents(on day: Date) -> [DayEvent] {
        usesSampleDay
            ? SampleDay.events(timed: dayDeveloper.sampleTimedCount,
                               allDay: dayDeveloper.sampleAllDayCount, on: day)
            : calendar.dayEvents(on: day)
    }

    #if DEBUG
    /// For the CLIO_DAY_SHOW tool: the card on a made-up day, kept up until
    /// closed. `CLIO_DAY_TIMED` and `CLIO_DAY_ALLDAY` say how many events,
    /// `CLIO_DAY_TIME=13:30` what time it is, `CLIO_DAY_LAYOUT`,
    /// `CLIO_DAY_POSITION` and `CLIO_DAY_COUNTDOWN` how it is drawn, and
    /// `CLIO_DAY_SECONDS` how long it stays instead.
    public func showSimulatedDay() {
        let env = ProcessInfo.processInfo.environment
        dayDeveloper.useSampleEvents = true
        dayDeveloper.sampleTimedCount = env["CLIO_DAY_TIMED"].flatMap(Int.init) ?? 12
        dayDeveloper.sampleAllDayCount = env["CLIO_DAY_ALLDAY"].flatMap(Int.init) ?? 3
        if let parts = env["CLIO_DAY_TIME"]?.split(separator: ":").compactMap({ Int($0) }),
           parts.count == 2,
           let date = Calendar.current.date(bySettingHour: parts[0], minute: parts[1],
                                            second: 0, of: Date()) {
            dayDeveloper.overridesTime = true
            dayDeveloper.overrideTime = date
        }
        var options = settingsStore.settings.dayPanelOptions
        options.seconds = env["CLIO_DAY_SECONDS"].flatMap(Double.init) ?? 0
        if let layout = env["CLIO_DAY_LAYOUT"].flatMap(DayLayout.init) { options.layout = layout }
        if let position = env["CLIO_DAY_POSITION"].flatMap(DayPanelPosition.init) {
            options.position = position
        }
        if let style = env["CLIO_DAY_COUNTDOWN"].flatMap(DayCountdownStyle.init) {
            options.countdownStyle = style
        }
        // The meeting cards go where the day view goes: the tool's place,
        // not the stored one — and never by writing the settings, which a
        // tool run would then save over the user's own.
        prepareMeetingOffer()
        meetingOffer?.dayPlacement = { [weak self] in (options.position, self?.dayPanel?.cardFrame) }
        // =call: not the day, but the card for a call that is starting —
        // which brings the day up with it, and takes it away when it goes.
        if env["CLIO_DAY_SHOW"] == "call" {
            previewOffer(.calendar)
            return
        }
        let now = dayClock
        panel().show(day: now, events: dayEvents(on: now), options: options)
    }
    #endif
}
