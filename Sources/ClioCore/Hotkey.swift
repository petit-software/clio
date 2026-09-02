import AppKit
import Carbon.HIToolbox

/// A hotkey is either a key + modifiers, or a modifiers-only chord.
public struct Hotkey: Codable, Equatable, Sendable {
    /// Virtual keycode (kVK_*). `nil` means this is a modifier-only chord.
    public var keyCode: UInt16?
    /// Raw value of NSEvent.ModifierFlags, masked to device-independent flags.
    public var modifierFlags: UInt

    public init(keyCode: UInt16?, modifierFlags: UInt) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
    }

    public var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
    }

    public var isModifierOnly: Bool { keyCode == nil }

    /// `fn` only reports on Apple-branded keyboards. Surface a warning in the UI.
    public var requiresAppleKeyboard: Bool { modifiers.contains(.function) }

    /// Does this event press this chord?
    public func matchesPress(type: HotkeyEventType,
                             keyCode: UInt16,
                             flags: NSEvent.ModifierFlags) -> Bool {
        if isModifierOnly {
            return type == .flagsChanged && !flags.isEmpty && flags == modifiers
        }
        return type == .keyDown && keyCode == self.keyCode && flags == modifiers
    }

    /// Does this event let go of this chord, given that it is held?
    public func matchesRelease(type: HotkeyEventType,
                               keyCode: UInt16,
                               flags: NSEvent.ModifierFlags) -> Bool {
        if isModifierOnly {
            return type == .flagsChanged && flags != modifiers
        }
        return type == .keyUp && keyCode == self.keyCode
    }

    /// Why these two cannot both be live, or nil if they can.
    ///
    /// A modifier-only chord fires the moment its modifiers are down, so a
    /// second chord that starts with those same modifiers — `fn` next to
    /// `fn Space`, say — could never be reached. Rejected when recorded rather
    /// than discovered at the desk.
    public static func conflict(between a: Hotkey, and b: Hotkey) -> String? {
        if a == b {
            return "Both shortcuts are the same."
        }
        for (first, second) in [(a, b), (b, a)]
        where first.isModifierOnly && second.modifiers.isSuperset(of: first.modifiers) {
            return "\(first.displayString) would fire before "
                + "\(second.displayString) could."
        }
        return nil
    }

    public static let defaultHotkey = Hotkey(
        keyCode: UInt16(kVK_ANSI_Semicolon),
        modifierFlags: NSEvent.ModifierFlags.control.rawValue
    )

    /// "⌃;" — for the settings row and the menu bar.
    public var displayString: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }
        if modifiers.contains(.function) { parts += "fn" }
        guard let keyCode else { return parts.isEmpty ? "—" : parts }
        return parts + Self.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_Semicolon: return ";"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_ANSI_Grave: return "`"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        default:
            // Ask the current keyboard layout what this key produces, so a
            // non-US layout shows the character actually printed on the cap.
            return layoutCharacter(for: keyCode) ?? "Key \(keyCode)"
        }
    }

    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?
            .takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(
                source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
        return (data as Data).withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?
                .assumingMemoryBound(to: UCKeyboardLayout.self)
            else { return nil }

            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, keyCode, UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeys, characters.count, &length, &characters)

            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }
}

public enum HotkeyMode: String, Codable, Sendable, CaseIterable {
    /// Hold to record, release to transcribe.
    case pushToTalk
    /// Tap to start, tap again to stop.
    case toggle

    public var label: String {
        switch self {
        case .pushToTalk: return "Push to talk"
        case .toggle: return "Toggle"
        }
    }
}

/// The subset of CGEventType the matcher cares about, so it can be driven
/// from a test without a real event tap.
public enum HotkeyEventType: Sendable {
    case keyDown
    case keyUp
    case flagsChanged
}

public enum HotkeyEvent: Sendable {
    case begin      // start recording
    case end        // stop recording, transcribe
    case cancel     // Esc — discard
}
