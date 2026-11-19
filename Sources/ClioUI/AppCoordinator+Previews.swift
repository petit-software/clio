import Foundation
import ClioCore

/// The cards and the pill, shown on request with nothing behind them: for
/// looking at them without a call, a calendar or a microphone. Settings ▸
/// About ▸ Developer, in builds that are not releases.
extension AppCoordinator {

    /// Whether this is a build made here rather than a release: a debug
    /// build, or one `build-app.sh` made — `release.sh` is what stamps the
    /// build number, and leaves nothing at 1.
    public static var isDeveloperBuild: Bool {
        #if DEBUG
        return true
        #else
        return (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) == "1"
        #endif
    }

    public enum OfferPreview: String, CaseIterable, Sendable {
        /// A call app opened its microphone.
        case call
        /// The calendar says a call is starting.
        case calendar
        /// The call a meeting was for has gone quiet.
        case countdown
    }

    /// Shows one of the meeting cards as it would appear, top right. Its
    /// buttons close it and do nothing else.
    public func previewOffer(_ kind: OfferPreview) {
        if meetingOffer == nil { meetingOffer = MeetingOfferController() }
        let event = MeetingEvent(
            id: "preview", title: "Weekly product sync",
            start: Date(), end: Date().addingTimeInterval(45 * 60),
            joinURL: URL(string: "https://us06web.zoom.us/j/88044921862?pwd=preview"),
            calendarColor: CalendarColor(red: 0.96, green: 0.58, blue: 0.25))
        switch kind {
        case .call:
            meetingOffer?.show(title: event.title,
                               app: CallApp(bundleID: "us.zoom.xos", name: "Zoom", isBrowser: false),
                               event: event, accept: {})
        case .calendar:
            meetingOffer?.show(
                MeetingOffer(headline: "“Weekly product sync” is starting",
                             detail: "Join the call and take notes? Both sides are transcribed on this Mac.",
                             acceptTitle: "Join & Take Notes", declineTitle: "Not Now",
                             event: event, offersLink: true),
                timeout: 45, accept: {})
        case .countdown:
            let seconds = CallWatch.stopCountdown
            meetingOffer?.show(
                MeetingOffer(headline: "The call seems to have ended",
                             detail: "Notes for “Weekly product sync” stop in %d s.",
                             acceptTitle: "Stop Now", declineTitle: "Keep Recording",
                             deadline: Date().addingTimeInterval(seconds)),
                timeout: seconds, accept: {})
        }
    }

    /// A whole dictation, as the pill tells it: listening, transcribing,
    /// copied.
    public func previewDictation() {
        previewPill([(.recording, 3), (.transcribing, 1.8), (.finished("Copied"), 1.6)])
    }

    /// The key pressed and nothing said.
    public func previewNothingHeard() {
        previewPill([(.recording, 1.5), (.emptyResult("Nothing heard"), 2.2)])
    }

    /// A dictation that went wrong.
    public func previewDictationError() {
        previewPill([(.recording, 1.5), (.transcribing, 1.2), (.failed("The model is not loaded"), 2.5)])
    }
}
