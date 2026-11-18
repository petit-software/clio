import AppKit
import ClioCore

/// Meeting notes: starting one, stopping it, and the window that shows it.
extension AppCoordinator {

    public var isMeetingActive: Bool { meeting?.isActive == true }

    /// Starts taking notes, named after `event` — or the calendar's current
    /// event when none is given — and opens the meeting window.
    ///
    /// - Parameter join: also opens the event's call link, for "Join and
    ///   Take Notes".
    ///
    /// `continuing` is the file of notes already written by hand — for an
    /// event, with nothing recorded: the recording goes into them.
    public func startMeeting(event: MeetingEvent? = nil, join: Bool = false,
                             callApp: CallApp? = nil, continuing: URL? = nil) {
        guard !isMeetingActive, !isStartingMeeting else {
            showMeetingWindow()
            return
        }
        guard let model = activeModel else {
            meetingProblem = "Download a speech model first, in Settings ▸ Model."
            MenuBarController.openSettings()
            return
        }
        meetingProblem = nil
        let settings = settingsStore.settings
        isStartingMeeting = true

        Task { @MainActor in
            defer { isStartingMeeting = false }
            // Asked the first time a meeting starts, not at launch: dictation
            // never needs the calendar.
            if calendar.access == .notDetermined {
                await calendar.requestAccess()
            }
            calendar.refresh()
            // Notes being carried on are named and peopled already; the
            // calendar's current event is not asked.
            let existing = continuing.flatMap { url in
                (library ?? MeetingLibrary(folder: url.deletingLastPathComponent())).record(at: url)
            }
            let event = existing == nil ? (event ?? calendar.current) : event

            let session = MeetingSession(
                title: existing?.title ?? event?.title ?? Self.defaultMeetingTitle(),
                folder: MeetingMarkdown.folder(customPath: settings.meetingsFolderPath),
                queue: engine,
                model: model,
                options: TranscribeOptions(
                    language: settings.language,
                    translateToEnglish: false,
                    initialPrompt: TranscriptFormatter.initialPrompt(
                        from: TranscriptFormatter.meetingVocabulary(
                            user: settings.customVocabulary,
                            title: existing?.title ?? event?.title,
                            attendees: existing?.attendees ?? event?.attendees ?? []))),
                sensitivity: settings.vadSensitivity,
                micDeviceUID: settings.inputDeviceUID)
            session.titleIsPlaceholder = event == nil && existing == nil
            session.keepsAudio = settings.meetingAudio != .off
            equip(session)
            session.currentModel = { [weak self] in self?.activeModel }
            if let event { session.apply(event) }
            if let existing, let continuing { session.adopt(existing, at: continuing) }
            if join, let url = event?.joinURL {
                NSWorkspace.shared.open(url)
            }

            meeting = session
            meetingOffer?.dismiss()
            // The call this meeting is part of, if one is on: when it lets
            // go of the microphone for good, the notes stop too.
            meetingCallApp = callApp ?? Self.callInProgress(event: event)
            callWatch.meetingStarted()
            showMeetingWindow()
            await session.start()
            if case .failed(let reason) = session.phase {
                meetingProblem = reason
            }
        }
    }

    /// What a session does when it ends, from what is installed and what
    /// Settings says: the voices told apart and named, the summary, the
    /// title. The same for a meeting recorded and a recording imported.
    func equip(_ session: MeetingSession) {
        let settings = settingsStore.settings
        // With the speaker models installed, the voices on the call are
        // told apart when it ends; with a summary model too, named.
        if let speakers = models.installed(.speaker).first {
            session.diarizer = SpeakerDiarizer(folder: speakers.url)
            let model = summaryModel
            session.nameVoices = { [weak self, weak session] record, voices in
                guard let self else { return [:] }
                return await self.nameVoices(of: record, voices, with: model, ending: session)
            }
            session.voicesIdentified = { [weak self] record, voices in
                guard let self, self.settingsStore.settings.rememberVoices else { return }
                await self.voiceMemory.remember(record, samples: voices.samples, space: voices.space)
                self.refreshVoiceCount()
            }
        }
        if settings.meetingSummaries, let model = summaryModel {
            session.summarize = { [weak self, weak session] record in
                await self?.makeRoomForSummary(by: model, ending: session)
                return await MeetingSummarizer.summarize(
                    record, with: model,
                    instructions: self?.settingsStore.settings.summaryPrompt)
            }
            session.suggestTitle = {
                await MeetingSummarizer.title(forSummary: $0, with: model)
            }
        }
    }

    /// Notes for a calendar event, written by hand: a file for it, with
    /// nothing recorded, opened to be typed in. Recording can be started
    /// from its page later, and goes into the same notes.
    public func writeNotes(for event: MeetingEvent) {
        let folder = MeetingMarkdown.folder(customPath: settingsStore.settings.meetingsFolderPath)
        do {
            let url = try MeetingMarkdown.write(MeetingRecord.notes(for: event), to: folder)
            library?.reload()
            showLibrary(selecting: .meeting(url))
        } catch {
            meetingProblem = "The notes could not be made: \(error.localizedDescription)"
        }
    }

    /// Join from the day's calendar: the call, and notes for it — or, if
    /// notes are already being taken, only the call, to rejoin it.
    public func join(_ event: MeetingEvent) {
        if isMeetingActive || isStartingMeeting {
            if let url = event.joinURL { NSWorkspace.shared.open(url) }
        } else {
            startMeeting(event: event, join: true)
        }
    }

    /// Stops the meeting; the window stays to show the last chunks and the
    /// summary arriving.
    public func stopMeeting() {
        guard let meeting, meeting.isActive else { return }
        Task { @MainActor in
            await meeting.stop()
            releaseModelsIfNotKept()
        }
    }

    /// Stops the meeting and transcribes what is left, without a summary,
    /// giving up after `seconds`: whatever is unfinished then is dropped.
    public func finishMeetingBeforeQuitting(within seconds: Double) async {
        guard let meeting, meeting.isActive else { return }
        // A race, not a task group: a group waits for every child at its
        // end, and the stop that lost would hold the quit up after all.
        final class Once { var done = false }
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            func finish() {
                guard !once.done else { return }
                once.done = true
                continuation.resume()
            }
            Task { @MainActor in
                await meeting.stop(summarizing: false)
                finish()
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                finish()
            }
        }
        if meeting.phase != .finished { meeting.abandon() }
    }

    /// The live meeting, in the library window.
    public func showMeetingWindow() {
        showLibrary(selecting: meeting?.isActive == true ? .live
                    : meeting?.fileURL.map(LibrarySelection.meeting))
    }

    /// Opens the library window, on `selection` if given.
    public func showLibrary(selecting selection: LibrarySelection? = nil) {
        let folder = MeetingMarkdown.folder(customPath: settingsStore.settings.meetingsFolderPath)
        if let library {
            library.setFolder(folder)
            library.reload()
        } else {
            library = MeetingLibrary(folder: folder)
        }
        if let selection { librarySelection = selection }
        // The meeting on now is on today's page.
        if selection == .live { libraryDay = Calendar.current.startOfDay(for: Date()) }
        if libraryWindow == nil { libraryWindow = LibraryWindowController() }
        libraryWindow?.show(coordinator: self)
    }

    /// Forgets one dictation, and leaves the library on nothing if it was
    /// the one showing.
    public func removeDictation(id: UUID) {
        history.remove(id: id)
        #if DEBUG
        libraryDictationsOverride?.removeAll { $0.id == id }
        #endif
        if librarySelection == .dictation(id) { librarySelection = nil }
    }

    /// Whether the library can show the calendar.
    public var libraryCalendarAccess: MeetingCalendar.Access {
        #if DEBUG
        if libraryEventsOverride != nil { return .granted }
        #endif
        return calendar.access
    }

    /// Any day's calendar events, for the library's day browser.
    public func dayEvents(on day: Date) -> [MeetingEvent] {
        #if DEBUG
        if let libraryEventsOverride {
            let calendar = Calendar.current
            return libraryEventsOverride.filter { calendar.isDate($0.start, inSameDayAs: day) }
                .sorted { $0.start < $1.start }
        }
        #endif
        return calendar.events(on: day)
    }

    /// Settings moved the notes folder.
    public func meetingsFolderChanged() {
        library?.setFolder(MeetingMarkdown.folder(customPath: settingsStore.settings.meetingsFolderPath))
        // The server reads the folder it was started on.
        updateMCPServer()
    }

    /// Dictations for the sidebar: whatever the history keeps — the last
    /// twenty, on disk only if Settings says so. The library does not keep
    /// any more than that.
    public var libraryDictations: [TranscriptEntry] {
        #if DEBUG
        if let libraryDictationsOverride { return libraryDictationsOverride }
        #endif
        return history.entries
    }

    // MARK: Noticing calls

    /// Every five seconds: is a call app on the microphone? Offers notes
    /// when a call starts, and stops a meeting when its call ends. Cheap —
    /// a handful of property reads from the HAL — and nothing is opened.
    func watchForCalls() {
        callWatchTask?.cancel()
        callWatchTask = Task { [weak self] in
            var checks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                checks += 1
                // Today's events change slowly; read them once a minute.
                if checks % 12 == 0 { self.calendar.refresh() }
                // Audio past its thirty days: looked for once an hour.
                if checks % 720 == 0 { self.sweepMeetingAudio() }
                self.checkForCalls()
            }
        }
    }

    private func checkForCalls() {
        let apps = CallDetection.appsUsingMicrophone()
        guard !isStartingMeeting else { return }
        if let meeting, meeting.isActive {
            if let app = meetingCallApp, callWatch.callEnded(app: app, apps: apps) {
                meetingCallApp = nil
                offerToKeepRecording(meeting)
            }
            return
        }
        guard settingsStore.settings.meetingDetection, activeModel != nil else { return }
        if meetingOffer == nil { meetingOffer = MeetingOfferController() }
        let event = calendar.access == .granted ? calendar.current : nil
        if let app = callWatch.offer(apps: apps, event: event) {
            meetingOffer?.show(title: event?.title, app: app, accept: { [weak self] in
                self?.startMeeting(event: event, callApp: app)
            }, decline: { [weak self] in
                self?.callWatch.decline(event)
            })
            return
        }
        // No call app on the microphone yet — but the calendar says a call
        // is starting: the same card, a moment before anything is joined.
        guard calendar.access == .granted, meetingOffer?.isShowing != true,
              let starting = callWatch.starting(events: dayEvents(on: Date())) else { return }
        let joins = starting.joinURL != nil
        meetingOffer?.show(
            MeetingOffer(headline: "“\(starting.title)” is starting",
                         detail: joins ? "Join the call and take notes? Both sides are transcribed on this Mac."
                                       : "Take notes for it? Both sides are transcribed on this Mac.",
                         acceptTitle: joins ? "Join & Take Notes" : "Take Notes",
                         declineTitle: "Not Now"),
            timeout: 45,
            accept: { [weak self] in self?.startMeeting(event: starting, join: joins) },
            decline: { [weak self] in self?.callWatch.decline(starting) })
    }

    /// The call a meeting was started for has let go of the microphone for
    /// half a minute. The notes stop — in a few seconds, and not without
    /// saying so: a call app also lets go for a long mute, or a change of
    /// headphones, and a meeting ended behind the user's back is one they
    /// find out about afterwards.
    private func offerToKeepRecording(_ meeting: MeetingSession) {
        if meetingOffer == nil { meetingOffer = MeetingOfferController() }
        let seconds = CallWatch.stopCountdown
        let stop: () -> Void = { [weak self, weak meeting] in
            guard let self, let meeting, self.meeting === meeting, meeting.isActive else { return }
            self.stopMeeting()
        }
        meetingOffer?.show(
            MeetingOffer(headline: "The call seems to have ended",
                         detail: "Notes for “\(meeting.record.title)” stop in %d s.",
                         acceptTitle: "Stop Now", declineTitle: "Keep Recording",
                         deadline: Date().addingTimeInterval(seconds)),
            timeout: seconds,
            accept: stop,
            // Kept: the call is not watched any more, so it is not asked again.
            decline: {},
            onTimeout: stop)
    }

    /// Deletes kept audio that is past the time Settings gives it. Nothing
    /// when audio is kept for good — or not kept at all: what was kept
    /// under an earlier setting is the user's to delete.
    public func sweepMeetingAudio() {
        let settings = settingsStore.settings
        guard let days = settings.meetingAudio.days else { return }
        let folder = MeetingMarkdown.folder(customPath: settings.meetingsFolderPath)
        Task.detached(priority: .utility) {
            MeetingAudio.removeExpired(in: folder, olderThan: days)
        }
    }

    /// A call app on the microphone now — or a browser, during a calendar
    /// call. Nil for notes taken in a room.
    static func callInProgress(event: MeetingEvent?) -> CallApp? {
        let apps = CallDetection.appsUsingMicrophone()
        return apps.first { !$0.isBrowser }
            ?? (event?.joinURL != nil || (event?.attendees.count ?? 0) > 1
                ? apps.first : nil)
    }

    /// A whole meeting, for real, from the bundle: both streams for
    /// `seconds`, transcribed, stopped, summarised where macOS can, and the
    /// Markdown returned. Into a temporary folder, not the user's notes.
    ///
    ///     (sleep 2; say "First thing.") & CLIO_MEETING_TEST=20 Clio.app/Contents/MacOS/Clio
    public func runMeetingCheck(seconds: Double) async -> String {
        guard let model = activeModel else { return "[meeting] FAILED: no model installed" }
        let settings = settingsStore.settings
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-meeting-check-\(UUID().uuidString)")
        let session = MeetingSession(
            title: "Meeting check", folder: folder, queue: engine, model: model,
            options: TranscribeOptions(language: settings.language),
            sensitivity: settings.vadSensitivity, micDeviceUID: settings.inputDeviceUID)
        if let model = summaryModel {
            session.summarize = { await MeetingSummarizer.summarize($0, with: model) }
        }
        let began = Date()
        await session.start()
        if case .failed(let reason) = session.phase { return "[meeting] FAILED: \(reason)" }
        try? await Task.sleep(for: .seconds(seconds))
        let stopping = Date()
        await session.stop()
        let markdown = session.fileURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return """
            [meeting] system audio: \(session.systemAudio), lines: \(session.record.lines.count), \
            summary: \(session.record.summary == nil ? "none" : "yes, by \(summaryModelName)"), \
            stop took \(String(format: "%.1f", Date().timeIntervalSince(stopping))) s \
            of \(String(format: "%.1f", Date().timeIntervalSince(began))) s
            [meeting] file: \(session.fileURL?.path ?? "none")
            \(markdown)
            """
    }

    /// The folder the notes go to, in Finder.
    public func revealMeetingsFolder() {
        let folder = MeetingMarkdown.folder(customPath: settingsStore.settings.meetingsFolderPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    static func defaultMeetingTitle(at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return "Meeting at \(formatter.string(from: date))"
    }
}

#if DEBUG
extension AppCoordinator {
    /// For CLIO_MEETING_SHOW.
    /// A sample attendee with the address the calendar would have given.
    private func samplePerson(_ name: String, declined: Bool = false) -> MeetingAttendee {
        let address = name.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
        return MeetingAttendee(name: name, declined: declined, email: address)
    }

    public func showSimulatedMeeting(_ which: String) {
        var record = MeetingRecord(title: "Weekly product sync",
                                   startDate: Date().addingTimeInterval(-1_520))
        record.attendees = [samplePerson("Ana Ruiz"), samplePerson("Bo Chen"),
                            samplePerson("Kit Lee", declined: true)]
        record.notes = "- iOS beta date?\n- pricing page copy"
        let lines: [(MeetingSpeaker, TimeInterval, String)] = [
            (.others, 4, "Okay, I think everyone's here. Let's start with the beta."),
            (.me, 9, "The build is ready. I'd like to send it to testers on Thursday."),
            (.others, 16, "Thursday works. Do we have the release notes?"),
            (.me, 21, "Not yet, I'll write them tomorrow morning."),
            (.others, 30, "Great. Next, the pricing page — Bo, where are we?"),
            (.others, 35, "Copy is drafted, design wants one more pass on the table."),
        ]
        for (speaker, start, text) in lines {
            record.add(MeetingLine(speaker: speaker, start: start, end: start + 4, text: text))
        }
        let phase: MeetingSession.Phase
        var audio = MeetingSession.SystemAudioStatus.listening
        switch which {
        case "finishing": phase = .finishing
        case "finished":
            phase = .finished
            record.endDate = Date()
            record.summary = """
                ### iOS beta
                - Build is ready; goes to testers Thursday.

                ### Pricing page
                - Copy drafted; design reviewing the table.

                ### Next steps
                - [ ] Write the release notes — Me
                """
        case "silent":
            phase = .recording
            audio = .silent
        case "refused":
            phase = .recording
            audio = .refused
        default: phase = .recording
        }
        meeting = MeetingSession.simulated(record: record, phase: phase, systemAudio: audio,
                                           pendingChunks: phase == .finishing ? 2 : 0)
        libraryDictationsOverride = []
        showLibrary(selecting: .live)
    }

    /// For CLIO_LIBRARY_SHOW: the library window on a folder of sample
    /// meetings in a temporary directory — never the user's own — with
    /// sample dictations, and a meeting recording at the top for "live".
    public func showSimulatedLibrary(_ which: String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-library-sample", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let now = Date()
        func sample(_ title: String, hoursAgo: Double, minutes: Double, people: [String],
                     notes: String, summary: String?, lines: [(MeetingSpeaker, String)],
                     voices: Bool = false) {
            var record = MeetingRecord(title: title, startDate: now.addingTimeInterval(-hoursAgo * 3600))
            record.endDate = record.startDate.addingTimeInterval(minutes * 60)
            record.attendees = people.map { samplePerson($0) }
            record.notes = notes
            record.summary = summary
            var others = 0
            for (index, line) in lines.enumerated() {
                let start = Double(index) * 9 + 3
                // Two voices on the call, taking turns: one a model has
                // named, one still a number.
                var voice: Int?
                if voices, line.0 == .others {
                    voice = others % 2 + 1
                    others += 1
                }
                record.add(MeetingLine(speaker: line.0, start: start, end: start + 6,
                                       text: line.1, voice: voice))
            }
            if voices { record.name(voice: 1, as: "Ana Ruiz", confirmed: false) }
            let written = try? MeetingMarkdown.write(record, to: folder)
            // The meeting with voices has its audio kept too: a tone, so
            // the page shows what a meeting with audio shows.
            if voices, let written, let recording = try? StreamRecording() {
                let second = (0..<16_000).map { 0.05 * sin(2 * .pi * 220 * Float($0) / 16_000) }
                for _ in 0..<150 { recording.append(second) }
                recording.close()
                for side in MeetingAudio.Side.allCases {
                    try? MeetingAudio.encode(recording: recording.url,
                                             to: MeetingAudio.url(for: written, side: side))
                }
                recording.discard()
            }
        }
        sample("Weekly product sync", hoursAgo: 2, minutes: 32, people: ["Ana Ruiz", "Bo Chen"],
                notes: "## Before the call\n- iOS beta **date**? <!--02:10-->\n- pricing page *copy*, which has to go to design before the table is final and to legal after that, so it cannot ship before the week after the beta at the earliest <!--14:35-->\n  - the `starter` tier\n\n## Follow-ups\n- [x] send the build to Ana\n- [ ] write the release notes for the beta and send them round to everyone who was on the call, with the list of what changed since the last build\n- [ ] write the release notes\n\n## Order\n1. beta to testers, starting with the ones who reported the import bug so that they can confirm it is gone before anyone else sees it\n2. pricing table\n\n> Bo: ship it when the table is final\n\nSee [the spec](https://example.com/spec) and ~~the old plan~~.",
                summary: "### iOS beta\n- Build is ready; goes to testers Thursday.\n\n### Pricing page\n- Copy drafted; design reviewing the table.\n\n### Next steps\n- [ ] Write the release notes — Me\n- [ ] Final pass on the pricing table — Bo",
                lines: [(.others, "Okay, I think everyone's here. Let's start with the beta."),
                        (.me, "The build is ready. I'd like to send it to testers on Thursday."),
                        (.others, "Thursday works. Do we have the release notes?"),
                        (.me, "Not yet, I'll write them tomorrow morning.")]
                    + (0..<14).flatMap { round -> [(MeetingSpeaker, String)] in
                        [(.others, "Point \(round + 1): the pricing table needs one more pass before it goes out, and design wants to try the darker variant."),
                         (.me, "Agreed on point \(round + 1). I'll check the numbers again and send them round this afternoon.")]
                    },
                voices: true)
        sample("1:1 with Ana", hoursAgo: 5, minutes: 25, people: ["Ana Ruiz"],
                notes: "", summary: "### Hiring\n- Two onsite interviews next week.",
                lines: [(.others, "How are the interviews going?"), (.me, "Two onsites next week.")])
        sample("Design review", hoursAgo: 27, minutes: 45, people: ["Kit Lee", "Bo Chen"],
                notes: "icon contrast", summary: nil,
                lines: [(.others, "The icon needs more contrast on dark backgrounds.")])
        sample("Quarterly planning", hoursAgo: 24 * 34, minutes: 80,
                people: ["Ana Ruiz", "Bo Chen", "Kit Lee"], notes: "",
                summary: "### Q1 goals\n- Ship meetings.",
                lines: [(.others, "Let's agree the three goals for the quarter.")])

        // A day of events around the samples: two with notes (matched by
        // time and title), one that passed without notes, one still to come
        // with a call to join.
        let work = CalendarColor(red: 0.20, green: 0.48, blue: 0.97)
        let personal = CalendarColor(red: 0.98, green: 0.58, blue: 0.12)
        func event(_ id: String, _ title: String, hoursAgo: Double, minutes: Double,
                   link: Bool = false, people: [String] = [],
                   on calendar: CalendarColor) -> MeetingEvent {
            let start = now.addingTimeInterval(-hoursAgo * 3600)
            return MeetingEvent(id: id, title: title, start: start,
                                end: start.addingTimeInterval(minutes * 60),
                                attendees: people.map { samplePerson($0) },
                                joinURL: link ? URL(string: "https://zoom.us/j/123456789") : nil,
                                calendarColor: calendar)
        }
        libraryEventsOverride = [
            event("sync", "Weekly product sync", hoursAgo: 2, minutes: 30, link: true,
                  people: ["Ana Ruiz", "Bo Chen"], on: work),
            event("lunch", "Team lunch", hoursAgo: 0.75, minutes: 30, on: personal),
            event("pricing", "Pricing call", hoursAgo: -0.75, minutes: 30, link: true,
                  people: ["Kit Lee", "Ana Ruiz"], on: work),
            event("review", "Roadmap review", hoursAgo: -3, minutes: 60, people: ["Bo Chen"],
                  on: work),
        ]
        libraryDay = Calendar.current.startOfDay(for: now)

        library = MeetingLibrary(folder: folder)
        libraryDictationsOverride = [
            TranscriptEntry(text: "Let's ship the microphone picker before the icon work.",
                            date: now.addingTimeInterval(-600)),
            TranscriptEntry(text: "Remember to re-grant accessibility after the next build.",
                            date: now.addingTimeInterval(-7200)),
        ]
        if which == "live" {
            var record = MeetingRecord(title: "Pricing call", startDate: now.addingTimeInterval(-754))
            record.attendees = [samplePerson("Kit Lee")]
            record.add(MeetingLine(speaker: .others, start: 4, end: 9,
                                   text: "Can we talk about the starter tier first?"))
            record.add(MeetingLine(speaker: .me, start: 12, end: 18,
                                   text: "Sure. I think it should stay at nine dollars."))
            meeting = MeetingSession.simulated(record: record, phase: .recording)
            librarySelection = .live
        } else if which == "dictation", let first = libraryDictationsOverride?.first {
            librarySelection = .dictation(first.id)
        } else if which == "empty" {
            librarySelection = nil
        } else if which == "event" {
            librarySelection = .event("pricing")
        } else {
            librarySelection = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if let first = library?.files.first { librarySelection = .meeting(first.url) }
            }
        }
        if libraryWindow == nil { libraryWindow = LibraryWindowController() }
        libraryWindow?.show(coordinator: self)
        if let typed = ProcessInfo.processInfo.environment["CLIO_TYPE"] {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                MarkdownTextView.typeIntoFocused(typed)
            }
        }
    }

    /// For CLIO_OFFER_SHOW.
    public func showSimulatedOffer() {
        if meetingOffer == nil { meetingOffer = MeetingOfferController() }
        meetingOffer?.show(title: "Weekly product sync",
                           app: CallApp(bundleID: "us.zoom.xos", name: "Zoom", isBrowser: false)) {
            FileHandle.standardError.write(Data("[offer] Take Notes pressed\n".utf8))
        }
    }

    /// For CLIO_OFFER_SHOW=click: shows the card, clicks "Take Notes" once
    /// while Clio is not the active app, and says whether it was heard.
    public func clickSimulatedOffer() {
        showSimulatedOffer()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            // "Take Notes": the right half of the button row, near the bottom.
            let size = MeetingOfferController.cardSize, margin = MeetingOfferController.shadowMargin
            meetingOffer?.click(at: NSPoint(x: margin + size.width * 0.75, y: margin + 30))
            try? await Task.sleep(for: .seconds(0.5))
            FileHandle.standardError.write(Data("[offer] click sent\n".utf8))
            exit(0)
        }
    }
}
#endif
