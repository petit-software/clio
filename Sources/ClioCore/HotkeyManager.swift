//
//  HotkeyManager.swift
//  Clio
//
//  Global hotkey handling for push-to-talk and toggle dictation.
//
//  Requires the Accessibility permission (AXIsProcessTrusted). Without it,
//  CGEvent.tapCreate returns nil.
//
//  Design notes:
//  - We use a listen-only session event tap so we never swallow the user's
//    keystrokes. If you want the hotkey to be *consumed* (not passed through
//    to the frontmost app), switch to .defaultTap and return nil from the
//    callback for matching events.
//  - The tap callback runs on a dedicated run loop. It does essentially no
//    work: it matches the event and hops to the main actor. macOS disables
//    taps that take too long (kCGEventTapDisabledByTimeout), so this matters.
//  - Modifier-only chords (e.g. "hold right Option") are handled through
//    flagsChanged, since they never produce keyDown/keyUp.
//
//  The model types (Hotkey, HotkeyMode, HotkeyEvent) live in Hotkey.swift.
//

import AppKit
import Carbon.HIToolbox

@MainActor
public final class HotkeyManager {

    // MARK: Public

    /// Called on the main actor for every recognized hotkey action.
    public var onEvent: ((HotkeyEvent) -> Void)?

    public private(set) var isActive = false

    /// Whether a session is running that Esc should abandon.
    ///
    /// Not the same as `isActive`, which only knows about sessions this
    /// manager started. A dictation begun from the menu bar left Esc dead,
    /// because from here it looked like nothing was happening.
    public var isSessionActive: (() -> Bool)?

    public var hotkey: Hotkey = .defaultHotkey {
        didSet { if hotkey != oldValue { reset() } }
    }

    public var mode: HotkeyMode = .pushToTalk {
        didSet { if mode != oldValue { reset() } }
    }

    /// Minimum hold before push-to-talk actually begins, so a stray tap
    /// doesn't produce a 40ms recording.
    public var holdThreshold: TimeInterval = 0.18

    public var isRunning: Bool { eventTap != nil }

    public init() {}

    // MARK: Private state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    /// Written by the tap thread, read by the main actor on stop(). A
    /// CFRunLoop is not Sendable, so it travels in a locked box rather than
    /// across an isolation boundary.
    private let tapRunLoop = RunLoopBox()

    private var isChordDown = false
    private var holdTask: Task<Void, Never>?
    private var trustPollTimer: Timer?

    // MARK: Lifecycle

    public func start() throws {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else {
            beginTrustPolling()
            throw HotkeyError.accessibilityNotTrusted
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: refcon
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        // Run the tap on its own thread so main-actor work never stalls it.
        // CFMachPort and CFRunLoopSource are thread-safe by design but are
        // imported as non-Sendable, so the capture is spelled out as safe.
        let box = tapRunLoop
        nonisolated(unsafe) let tapRef = tap
        nonisolated(unsafe) let sourceRef = source
        let thread = Thread {
            let loop = CFRunLoopGetCurrent()
            box.loop = loop
            CFRunLoopAddSource(loop, sourceRef, .commonModes)
            CGEvent.tapEnable(tap: tapRef, enable: true)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        thread.name = "com.clio.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
    }

    public func stop() {
        holdTask?.cancel()
        holdTask = nil
        trustPollTimer?.invalidate()
        trustPollTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let loop = tapRunLoop.loop, let source = runLoopSource {
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopStop(loop)
        }
        tapThread?.cancel()
        tapThread = nil
        tapRunLoop.loop = nil
        runLoopSource = nil
        eventTap = nil
        isChordDown = false
        isActive = false
    }

    /// Rebuild the tap in place — used after the hotkey or mode changes and
    /// after Accessibility is re-granted.
    public func restart() {
        stop()
        try? start()
    }

    private func reset() {
        if isActive { emit(.cancel) }
        isChordDown = false
        holdTask?.cancel()
        holdTask = nil
        isActive = false
    }

    // MARK: Tap callback (off the main actor)

    fileprivate nonisolated func handleFromTap(type: CGEventType, event: CGEvent) {
        // macOS disables taps that are slow or that error out. Re-enable and bail.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let tap = self?.eventTap else { return }
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
            .intersection(.deviceIndependentFlagsMask)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        Task { @MainActor [weak self] in
            self?.process(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        }
    }

    // MARK: Matching (main actor)

    private func process(
        type: CGEventType,
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) {
        // Esc always cancels an in-flight session, whatever the hotkey is and
        // whatever started it.
        if type == .keyDown, keyCode == UInt16(kVK_Escape),
           isActive || isSessionActive?() == true {
            cancelSession()
            return
        }

        if hotkey.isModifierOnly {
            guard type == .flagsChanged else { return }
            let matched = flags == hotkey.modifiers && !flags.isEmpty
            if matched && !isChordDown {
                isChordDown = true
                chordPressed()
            } else if !matched && isChordDown {
                isChordDown = false
                chordReleased()
            }
            return
        }

        guard keyCode == hotkey.keyCode else { return }

        switch type {
        case .keyDown:
            guard !isRepeat else { return }
            guard flags == hotkey.modifiers else { return }
            guard !isChordDown else { return }
            isChordDown = true
            chordPressed()

        case .keyUp:
            guard isChordDown else { return }
            isChordDown = false
            chordReleased()

        default:
            break
        }
    }

    // MARK: Semantics

    private func chordPressed() {
        switch mode {
        case .toggle:
            if isActive { endSession() } else { beginSession() }

        case .pushToTalk:
            // Wait out the hold threshold before committing to a recording.
            holdTask?.cancel()
            holdTask = Task { [weak self, holdThreshold] in
                try? await Task.sleep(for: .seconds(holdThreshold))
                guard !Task.isCancelled else { return }
                guard let self, self.isChordDown, !self.isActive else { return }
                self.beginSession()
            }
        }
    }

    private func chordReleased() {
        switch mode {
        case .toggle:
            break // handled entirely on press

        case .pushToTalk:
            holdTask?.cancel()
            holdTask = nil
            if isActive { endSession() }
        }
    }

    private func beginSession() {
        isActive = true
        emit(.begin)
    }

    private func endSession() {
        isActive = false
        emit(.end)
    }

    private func cancelSession() {
        isActive = false
        holdTask?.cancel()
        holdTask = nil
        emit(.cancel)
    }

    private func emit(_ event: HotkeyEvent) {
        onEvent?(event)
    }

    // MARK: Accessibility trust

    /// Accessibility can be revoked while we're running, which silently kills
    /// the tap. Poll and re-install when it comes back.
    public func beginTrustPolling() {
        trustPollTimer?.invalidate()
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self, AXIsProcessTrusted(), self.eventTap == nil else { return }
                try? self.start()
                self.trustPollTimer?.invalidate()
                self.trustPollTimer = nil
            }
        }
    }

    public static func requestAccessibilityTrust() {
        // The string literal rather than kAXTrustedCheckOptionPrompt: that
        // constant is imported as a mutable global, which Swift 6 rejects as
        // shared mutable state. Its value is this and is API-stable.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

/// The tap callback, deliberately at file scope rather than a closure inside
/// `start()`.
///
/// A closure literal written inside a @MainActor type inherits main-actor
/// isolation. As a C function pointer it cannot hop, so the compiler emits a
/// runtime isolation assertion at entry instead — which fires on the tap
/// thread and kills the process with EXC_BREAKPOINT on the first key event.
/// A file-scope function is nonisolated, so no check is emitted.
private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    manager.handleFromTap(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

/// Locked storage for the tap thread's run loop.
private final class RunLoopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CFRunLoop?

    var loop: CFRunLoop? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

public enum HotkeyError: LocalizedError {
    case accessibilityNotTrusted
    case tapCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Clio needs Accessibility access to listen for its shortcut."
        case .tapCreationFailed:
            return "Could not create the keyboard event tap."
        }
    }
}
