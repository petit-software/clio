//
//  HotkeyManager.swift
//  Whisperbar
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

import AppKit
import Carbon.HIToolbox

// MARK: - Model

/// A hotkey is either a key + modifiers, or a modifiers-only chord.
struct Hotkey: Codable, Equatable, Sendable {
    /// Virtual keycode (kVK_*). `nil` means this is a modifier-only chord.
    var keyCode: UInt16?
    /// Raw value of NSEvent.ModifierFlags, masked to device-independent flags.
    var modifierFlags: UInt

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
    }

    var isModifierOnly: Bool { keyCode == nil }

    /// `fn` only reports on Apple-branded keyboards. Surface a warning in the UI.
    var requiresAppleKeyboard: Bool { modifiers.contains(.function) }

    static let defaultHotkey = Hotkey(
        keyCode: UInt16(kVK_ANSI_Semicolon),
        modifierFlags: NSEvent.ModifierFlags.control.rawValue
    )
}

enum HotkeyMode: String, Codable, Sendable {
    /// Hold to record, release to transcribe.
    case pushToTalk
    /// Tap to start, tap again to stop.
    case toggle
}

enum HotkeyEvent: Sendable {
    case begin      // start recording
    case end        // stop recording, transcribe
    case cancel     // Esc — discard
}

// MARK: - Manager

@MainActor
final class HotkeyManager {

    // MARK: Public

    /// Called on the main actor for every recognized hotkey action.
    var onEvent: ((HotkeyEvent) -> Void)?

    private(set) var isActive = false

    var hotkey: Hotkey = .defaultHotkey {
        didSet { reset() }
    }

    var mode: HotkeyMode = .pushToTalk {
        didSet { reset() }
    }

    /// Minimum hold before push-to-talk actually begins, so a stray tap
    /// doesn't produce a 40ms recording.
    var holdThreshold: TimeInterval = 0.18

    // MARK: Private state

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    private var isChordDown = false
    private var holdTask: Task<Void, Never>?
    private var trustPollTimer: Timer?

    // MARK: Lifecycle

    func start() throws {
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
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>
                    .fromOpaque(refcon).takeUnretainedValue()
                manager.handleFromTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            throw HotkeyError.tapCreationFailed
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        // Run the tap on its own thread so main-actor work never stalls it.
        let thread = Thread { [weak self] in
            let loop = CFRunLoopGetCurrent()
            Task { @MainActor in self?.tapRunLoop = loop }
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
            }
        }
        thread.name = "com.whisperbar.hotkey-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        tapThread = thread
    }

    func stop() {
        holdTask?.cancel()
        holdTask = nil
        trustPollTimer?.invalidate()
        trustPollTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let loop = tapRunLoop, let source = runLoopSource {
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFRunLoopStop(loop)
        }
        tapThread?.cancel()
        tapThread = nil
        tapRunLoop = nil
        runLoopSource = nil
        eventTap = nil
        isChordDown = false
        isActive = false
    }

    private func reset() {
        if isActive { emit(.cancel) }
        isChordDown = false
        holdTask?.cancel()
        holdTask = nil
        isActive = false
    }

    // MARK: Tap callback (off the main actor)

    private nonisolated func handleFromTap(type: CGEventType, event: CGEvent) {
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
        // Esc always cancels an in-flight session, whatever the hotkey is.
        if type == .keyDown, keyCode == UInt16(kVK_Escape), isActive {
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
    func beginTrustPolling() {
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

    static func requestAccessibilityTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

enum HotkeyError: LocalizedError {
    case accessibilityNotTrusted
    case tapCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Whisperbar needs Accessibility access to listen for its shortcut."
        case .tapCreationFailed:
            return "Could not create the keyboard event tap."
        }
    }
}

// MARK: - Usage

/*
 let hotkeys = HotkeyManager()
 hotkeys.hotkey = settings.hotkey
 hotkeys.mode = settings.mode
 hotkeys.onEvent = { [weak coordinator] event in
     switch event {
     case .begin:  coordinator?.startRecording()
     case .end:    coordinator?.stopAndTranscribe()
     case .cancel: coordinator?.cancel()
     }
 }
 do { try hotkeys.start() }
 catch { presentOnboarding() }   // then HotkeyManager.requestAccessibilityTrust()
 */
