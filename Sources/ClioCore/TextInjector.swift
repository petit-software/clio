import AppKit
import Carbon.HIToolbox

/// Gets the transcript into whatever app the user was typing in (§5.6).
///
/// Clipboard + synthesized ⌘V, with the original clipboard put back. The
/// restore is conditional on `changeCount`: if something else wrote to the
/// pasteboard while we were pasting, that write wins and we leave it alone.
@MainActor
public enum TextInjector {

    public enum Result: Sendable, Equatable {
        case pasted
        case copiedOnly(reason: String?)
        case typed
    }

    /// Everything on the pasteboard, so restoring does not silently downgrade
    /// a copied image or RTF to plain text.
    struct Snapshot {
        let items: [[String: Data]]
        let changeCount: Int

        static func capture(from pasteboard: NSPasteboard = .general) -> Snapshot {
            let items = (pasteboard.pasteboardItems ?? []).map { item in
                var contents: [String: Data] = [:]
                for type in item.types {
                    if let data = item.data(forType: type) {
                        contents[type.rawValue] = data
                    }
                }
                return contents
            }
            return Snapshot(items: items, changeCount: pasteboard.changeCount)
        }

        func restore(to pasteboard: NSPasteboard = .general) {
            pasteboard.clearContents()
            guard !items.isEmpty else { return }
            let restored = items.map { contents -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in contents {
                    item.setData(data, forType: NSPasteboard.PasteboardType(type))
                }
                return item
            }
            pasteboard.writeObjects(restored)
        }
    }

    /// Put `text` in front of the user by whichever route the settings and the
    /// system allow.
    /// - Parameter keepOnClipboard: leave the transcript on the clipboard
    ///   afterwards. Pasting borrows the clipboard and puts back what was
    ///   there, so without this the transcript is gone the moment it lands.
    @discardableResult
    public static func inject(_ text: String,
                              action: OutputAction,
                              method: InjectionMethod,
                              keepOnClipboard: Bool = false,
                              pasteboard: NSPasteboard = .general) async -> Result {
        guard !text.isEmpty else { return .copiedOnly(reason: "Nothing was transcribed.") }

        // Secure input (password fields, some terminals) swallows synthetic
        // events entirely. Copying is the honest fallback — §5.6.
        if action == .pasteAutomatically, IsSecureEventInputEnabled() {
            copy(text, to: pasteboard)
            return .copiedOnly(reason: "Another app has secure input enabled, so the text was copied instead.")
        }

        guard action == .pasteAutomatically else {
            copy(text, to: pasteboard)
            return .copiedOnly(reason: nil)
        }

        guard AXIsProcessTrusted() else {
            copy(text, to: pasteboard)
            return .copiedOnly(reason: "Accessibility access is off, so the text was copied instead.")
        }

        switch method {
        case .typeCharacters:
            // Typing needs no clipboard at all; it is only touched when the
            // user asked to keep the transcript there.
            if keepOnClipboard { copy(text, to: pasteboard) }
            typeCharacters(text)
            return .typed

        case .paste:
            let snapshot = Snapshot.capture(from: pasteboard)
            copy(text, to: pasteboard)
            let ours = pasteboard.changeCount
            postCommandV()

            // Give the frontmost app time to read the pasteboard before we put
            // the old contents back.
            try? await Task.sleep(for: .milliseconds(150))
            if !keepOnClipboard, pasteboard.changeCount == ours {
                snapshot.restore(to: pasteboard)
            }
            return .pasted
        }
    }

    /// Clipboard only — also the path the menu bar's "Copy last transcript" uses.
    public static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: Synthesis

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return }

        // The flag has to be on BOTH events or some apps swallow the paste.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    /// Character-by-character fallback. Slower, and known to drop characters in
    /// some Electron apps, but it works where paste does not.
    private static func typeCharacters(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text.unicodeScalars {
            var utf16 = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cgAnnotatedSessionEventTap)
            up.post(tap: .cgAnnotatedSessionEventTap)
            usleep(2000)
        }
    }
}
