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
    public func startMeeting(event: MeetingEvent? = nil, join: Bool = false,
                             callApp: CallApp? = nil) {
        guard !isMeetingActive else {
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

        Task { @MainActor in
            // Asked the first time a meeting starts, not at launch: dictation
            // never needs the calendar.
            if calendar.access == .notDetermined {
                await calendar.requestAccess()
            }
            calendar.refresh()
            let event = event ?? calendar.current

            let session = MeetingSession(
                title: event?.title ?? Self.defaultMeetingTitle(),
                folder: MeetingMarkdown.folder(customPath: settings.meetingsFolderPath),
                queue: engine,
                model: model,
                options: TranscribeOptions(
                    language: settings.language,
                    translateToEnglish: false,
                    initialPrompt: TranscriptFormatter.initialPrompt(
                        from: settings.customVocabulary)),
                sensitivity: settings.vadSensitivity,
                micDeviceUID: settings.inputDeviceUID)
            if settings.meetingSummaries, MeetingSummarizer.isAvailable {
                session.summarize = { await MeetingSummarizer.summarize($0) }
            }
            if let event { session.apply(event) }
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

    /// Stops the meeting; the window stays to show the last chunks and the
    /// summary arriving.
    public func stopMeeting() {
        guard let meeting, meeting.isActive else { return }
        Task { @MainActor in
            await meeting.stop()
        }
    }

    public func showMeetingWindow() {
        guard let meeting else { return }
        if meetingWindow == nil {
            meetingWindow = MeetingWindowController()
        }
        meetingWindow?.show(meeting: meeting, coordinator: self)
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
                self.checkForCalls()
            }
        }
    }

    private func checkForCalls() {
        let apps = CallDetection.appsUsingMicrophone()
        if let meeting, meeting.isActive {
            if let app = meetingCallApp, callWatch.callEnded(app: app, apps: apps) {
                meetingCallApp = nil
                stopMeeting()
            }
            return
        }
        guard settingsStore.settings.meetingDetection, activeModel != nil else { return }
        let event = calendar.access == .granted ? calendar.current : nil
        guard let app = callWatch.offer(apps: apps, event: event) else { return }
        if meetingOffer == nil { meetingOffer = MeetingOfferController() }
        meetingOffer?.show(title: event?.title, app: app) { [weak self] in
            self?.startMeeting(event: event, callApp: app)
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
        if MeetingSummarizer.isAvailable {
            session.summarize = { await MeetingSummarizer.summarize($0) }
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
            summary: \(session.record.summary == nil ? "none" : "yes"), \
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
    public func showSimulatedMeeting(_ which: String) {
        var record = MeetingRecord(title: "Weekly product sync",
                                   startDate: Date().addingTimeInterval(-1_520))
        record.attendees = [MeetingAttendee(name: "Ana Ruiz"), MeetingAttendee(name: "Bo Chen"),
                            MeetingAttendee(name: "Kit Lee", declined: true)]
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
        default: phase = .recording
        }
        meeting = MeetingSession.simulated(record: record, phase: phase, systemAudio: audio,
                                           pendingChunks: phase == .finishing ? 2 : 0)
        showMeetingWindow()
    }

    /// For CLIO_OFFER_SHOW.
    public func showSimulatedOffer() {
        if meetingOffer == nil { meetingOffer = MeetingOfferController() }
        meetingOffer?.show(title: "Weekly product sync",
                           app: CallApp(bundleID: "us.zoom.xos", name: "Zoom", isBrowser: false)) {}
    }
}
#endif
