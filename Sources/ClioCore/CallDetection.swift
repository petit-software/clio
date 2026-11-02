import CoreAudio
import Foundation

/// An app that holds calls, caught using a microphone.
public struct CallApp: Equatable, Hashable, Sendable {
    public var bundleID: String
    public var name: String
    /// A browser uses the microphone for plenty that is not a call, so one
    /// only counts while the calendar says a call is on.
    public var isBrowser: Bool

    public init(bundleID: String, name: String, isBrowser: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isBrowser = isBrowser
    }
}

/// Which apps are on a call right now, asked of Core Audio rather than
/// guessed from window titles.
///
/// Every process that uses audio has an object in the HAL, and since macOS
/// 14.2 each says whether it is running input. A call app with its
/// microphone open is in a call; when it lets go, the call is over. That is
/// both ends of a meeting, for any app, with no permission beyond what Clio
/// already has.
public enum CallDetection {

    static let callApps: [String: String] = [
        "us.zoom.xos": "Zoom",
        "us.zoom.videomeeting": "Zoom",
        "com.microsoft.teams2": "Microsoft Teams",
        "com.microsoft.teams": "Microsoft Teams",
        "com.apple.FaceTime": "FaceTime",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.hnc.Discord": "Discord",
        "com.skype.skype": "Skype",
        "com.around.Around": "Around",
    ]

    /// Prefixes, because a browser's microphone is opened by a helper
    /// process with a bundle ID of its own: com.google.Chrome.helper, and
    /// for Safari the shared com.apple.WebKit.GPU.
    static let browserPrefixes: [(prefix: String, name: String)] = [
        ("com.google.Chrome", "Chrome"),
        ("com.apple.Safari", "Safari"),
        ("com.apple.WebKit", "Safari"),
        ("company.thebrowser", "Arc"),
        ("com.brave.Browser", "Brave"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.operasoftware", "Opera"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
    ]

    /// What a bundle ID is, as far as calls go.
    public static func classify(bundleID: String) -> CallApp? {
        if let name = callApps[bundleID] {
            return CallApp(bundleID: bundleID, name: name, isBrowser: false)
        }
        // Helpers of a call app ("us.zoom.xos.helper") count as the app.
        if let (id, name) = callApps.first(where: { bundleID.hasPrefix($0.key + ".") }) {
            return CallApp(bundleID: id, name: name, isBrowser: false)
        }
        if let browser = browserPrefixes.first(where: { bundleID.hasPrefix($0.prefix) }) {
            return CallApp(bundleID: browser.prefix, name: browser.name, isBrowser: true)
        }
        return nil
    }

    /// The call apps and browsers with a microphone open now. Empty before
    /// macOS 14.2, where the HAL does not say.
    public static func appsUsingMicrophone() -> Set<CallApp> {
        guard #available(macOS 14.2, *) else { return [] }
        var result = Set<CallApp>()
        for process in processObjects() where isRunningInput(process) {
            if let bundleID = bundleID(of: process), let app = classify(bundleID: bundleID) {
                result.insert(app)
            }
        }
        return result
    }

    // MARK: The HAL

    @available(macOS 14.2, *)
    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    @available(macOS 14.2, *)
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr
            && running != 0
    }

    @available(macOS 14.2, *)
    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(process, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        let id = value as String
        return id.isEmpty ? nil : id
    }
}

/// When to offer notes, and when a call has ended — the decisions, apart
/// from the polling, so they can be tested.
public struct CallWatch: Sendable {
    /// Calls already offered, so one call is offered once.
    private var offered: Set<String> = []
    /// Consecutive checks the meeting's call app has been off the microphone.
    private var quietChecks = 0

    /// How many checks in a row without the microphone end a meeting. At one
    /// check every five seconds, half a minute: long enough to survive a
    /// mute that closes the device, or a rejoin.
    public static let quietChecksToStop = 6

    public init() {}

    /// The call to offer notes for, if any: a call app on the microphone,
    /// or a browser on it while the calendar has a call on.
    public mutating func offer(apps: Set<CallApp>, event: MeetingEvent?) -> CallApp? {
        // Calls that ended may be offered again next time.
        offered = offered.filter { key in apps.contains { key.hasPrefix($0.bundleID + "|") } }
        let candidates = apps.filter { !$0.isBrowser || event?.isCall == true }
            .sorted { !$0.isBrowser && $1.isBrowser }
        for app in candidates {
            let key = "\(app.bundleID)|\(event?.id ?? "")"
            if offered.insert(key).inserted { return app }
        }
        return nil
    }

    /// Whether a meeting started for `app` should stop now.
    public mutating func callEnded(app: CallApp, apps: Set<CallApp>) -> Bool {
        if apps.contains(where: { $0.bundleID == app.bundleID }) {
            quietChecks = 0
            return false
        }
        quietChecks += 1
        return quietChecks >= Self.quietChecksToStop
    }

    public mutating func meetingStarted() {
        quietChecks = 0
    }
}
