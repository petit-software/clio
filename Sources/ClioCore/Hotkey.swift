import AppKit
import Carbon.HIToolbox

/// A hotkey is either one to three keys held together plus modifiers, or a
/// modifiers-only chord.
public struct Hotkey: Codable, Equatable, Sendable {
    /// The most keys a chord may hold at once.
    public static let maxKeys = 3

    /// Virtual keycodes (kVK_*), in the order they were recorded. Empty
    /// means this is a modifier-only chord. Never more than `maxKeys`.
    public var keyCodes: [UInt16]
    /// Raw value of NSEvent.ModifierFlags, masked to device-independent flags.
    public var modifierFlags: UInt

    public init(keyCodes: [UInt16], modifierFlags: UInt) {
        self.keyCodes = Array(keyCodes.prefix(Self.maxKeys))
        self.modifierFlags = modifierFlags
    }

    public init(keyCode: UInt16?, modifierFlags: UInt) {
        self.init(keyCodes: keyCode.map { [$0] } ?? [], modifierFlags: modifierFlags)
    }

    public var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags)
            .intersection(.deviceIndependentFlagsMask)
    }

    public var isModifierOnly: Bool { keyCodes.isEmpty }

    /// `fn` only reports on Apple-branded keyboards. Surface a warning in the UI.
    public var requiresAppleKeyboard: Bool { modifiers.contains(.function) }

    /// The same keys in a different order are the same chord.
    public static func == (a: Hotkey, b: Hotkey) -> Bool {
        a.modifiers == b.modifiers && Set(a.keyCodes) == Set(b.keyCodes)
    }

    // MARK: Codable

    /// Written as `keyCodes`, and read back from either that or the single
    /// `keyCode` that settings files from before multi-key chords carry.
    /// `keyCode` is still written — the first key — so a copy of Clio from
    /// before this can read the file and gets something rather than nothing.
    private enum CodingKeys: String, CodingKey {
        case keyCode, keyCodes, modifierFlags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let modifierFlags = try container.decode(UInt.self, forKey: .modifierFlags)
        if let codes = try container.decodeIfPresent([UInt16].self, forKey: .keyCodes) {
            self.init(keyCodes: codes, modifierFlags: modifierFlags)
        } else {
            let code = try container.decodeIfPresent(UInt16.self, forKey: .keyCode)
            self.init(keyCode: code, modifierFlags: modifierFlags)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCodes, forKey: .keyCodes)
        try container.encode(keyCodes.first, forKey: .keyCode)
        try container.encode(modifierFlags, forKey: .modifierFlags)
    }

    // MARK: Matching

    /// Does this event complete this chord?
    ///
    /// `heldKeys` is every non-modifier key currently down, including the one
    /// this event is for. A multi-key chord is pressed by whichever of its
    /// keys goes down last, so it fires once all of them are held.
    public func matchesPress(type: HotkeyEventType,
                             keyCode: UInt16,
                             flags: NSEvent.ModifierFlags,
                             heldKeys: Set<UInt16> = []) -> Bool {
        if isModifierOnly {
            return type == .flagsChanged && !flags.isEmpty && flags == modifiers
        }
        return type == .keyDown && keyCodes.contains(keyCode) && flags == modifiers
            && keyCodes.allSatisfy { $0 == keyCode || heldKeys.contains($0) }
    }

    /// Does this event let go of this chord, given that it is held? Letting
    /// go of any one of its keys is enough.
    public func matchesRelease(type: HotkeyEventType,
                               keyCode: UInt16,
                               flags: NSEvent.ModifierFlags) -> Bool {
        if isModifierOnly {
            return type == .flagsChanged && flags != modifiers
        }
        return type == .keyUp && keyCodes.contains(keyCode)
    }

    /// Why these two cannot both be live, or nil if they can.
    ///
    /// A modifier-only chord fires the moment its modifiers are down, so a
    /// second chord that starts with those same modifiers — `fn` next to
    /// `fn Space`, say — could never be reached. Likewise a chord whose keys
    /// are a subset of another's with the same modifiers: `⌃A` fires on the
    /// way to `⌃A+S`. Rejected when recorded rather than discovered at the
    /// desk.
    public static func conflict(between a: Hotkey, and b: Hotkey) -> String? {
        if a == b {
            return "Both shortcuts are the same."
        }
        for (first, second) in [(a, b), (b, a)] where first.shadows(second) {
            return "\(first.displayString) would fire before "
                + "\(second.displayString) could."
        }
        return nil
    }

    private func shadows(_ other: Hotkey) -> Bool {
        if isModifierOnly {
            return other.modifiers.isSuperset(of: modifiers)
        }
        return modifiers == other.modifiers
            && Set(keyCodes).isStrictSubset(of: Set(other.keyCodes))
    }

    public static let defaultHotkey = Hotkey(
        keyCode: UInt16(kVK_ANSI_Semicolon),
        modifierFlags: NSEvent.ModifierFlags.control.rawValue
    )

    /// "⌃;", or "⌃A+S" for keys held together — for the settings row and
    /// the menu bar.
    public var displayString: String {
        var parts = ""
        if modifiers.contains(.control) { parts += "⌃" }
        if modifiers.contains(.option) { parts += "⌥" }
        if modifiers.contains(.shift) { parts += "⇧" }
        if modifiers.contains(.command) { parts += "⌘" }
        if modifiers.contains(.function) { parts += "fn" }
        guard !keyCodes.isEmpty else { return parts.isEmpty ? "—" : parts }
        return parts + keyCodes.map(Self.keyName).joined(separator: "+")
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

    /// Text Input Sources aborts the process if it is entered from two
    /// threads at once — it says so, in the crash log. The app only asks from
    /// the main actor, but the tests run in parallel and a chord of letters
    /// asks once per key, so the lookup is serialised rather than trusted.
    private static let layoutLock = NSLock()

    private static func layoutCharacter(for keyCode: UInt16) -> String? {
        layoutLock.lock()
        defer { layoutLock.unlock() }

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
