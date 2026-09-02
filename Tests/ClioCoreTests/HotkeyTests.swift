import Testing
import AppKit
import Carbon.HIToolbox
@testable import ClioCore

// MARK: - Two chords at once

private let semicolon = UInt16(kVK_ANSI_Semicolon)
private let space = UInt16(kVK_Space)
private let control: NSEvent.ModifierFlags = .control
private let fn: NSEvent.ModifierFlags = .function

@MainActor
private func manager(mode: HotkeyMode = .toggle,
                     secondary: Hotkey? = nil) -> (HotkeyManager, () -> [HotkeyEvent]) {
    let manager = HotkeyManager()
    manager.mode = mode
    manager.hotkey = .defaultHotkey            // ⌃;
    manager.secondaryHotkey = secondary
    var events: [HotkeyEvent] = []
    manager.onEvent = { events.append($0) }
    return (manager, { events })
}

extension HotkeyEvent: Equatable {}

@MainActor
@Test("Either shortcut starts a dictation")
func eitherShortcutFires() {
    let (m, events) = manager(secondary: Hotkey(keyCode: nil, modifierFlags: fn.rawValue))

    // The primary, a key chord.
    m.process(type: .keyDown, keyCode: semicolon, flags: control, isRepeat: false)
    m.process(type: .keyUp, keyCode: semicolon, flags: control, isRepeat: false)
    #expect(events() == [.begin])

    // The secondary, modifier-only.
    m.process(type: .flagsChanged, keyCode: 0, flags: fn, isRepeat: false)
    m.process(type: .flagsChanged, keyCode: 0, flags: [], isRepeat: false)
    #expect(events() == [.begin, .end])
}

@MainActor
@Test("Push to talk ends on the release of the chord that started it")
func pushToTalkPairsPressAndRelease() async throws {
    let (m, events) = manager(mode: .pushToTalk,
                              secondary: Hotkey(keyCode: nil, modifierFlags: fn.rawValue))
    m.holdThreshold = 0.01

    m.process(type: .flagsChanged, keyCode: 0, flags: fn, isRepeat: false)
    try await Task.sleep(for: .milliseconds(60))
    #expect(events() == [.begin])

    // The other chord going up and down meanwhile is not a release.
    m.process(type: .keyDown, keyCode: semicolon, flags: [.control, .function], isRepeat: false)
    m.process(type: .keyUp, keyCode: semicolon, flags: [.control, .function], isRepeat: false)
    #expect(events() == [.begin])

    m.process(type: .flagsChanged, keyCode: 0, flags: [], isRepeat: false)
    #expect(events() == [.begin, .end])
}

@MainActor
@Test("A single shortcut behaves as before")
func singleShortcutUnchanged() {
    let (m, events) = manager()
    m.process(type: .keyDown, keyCode: semicolon, flags: control, isRepeat: false)
    m.process(type: .keyDown, keyCode: semicolon, flags: control, isRepeat: true)
    m.process(type: .keyUp, keyCode: semicolon, flags: control, isRepeat: false)
    // Wrong modifiers: nothing.
    m.process(type: .keyDown, keyCode: semicolon, flags: [], isRepeat: false)
    // Some other key: nothing.
    m.process(type: .keyDown, keyCode: space, flags: control, isRepeat: false)
    #expect(events() == [.begin])
}

@MainActor
@Test("Changing the alternate shortcut resets a held chord")
func changingSecondaryResets() {
    let (m, events) = manager(secondary: Hotkey(keyCode: nil, modifierFlags: fn.rawValue))
    m.process(type: .flagsChanged, keyCode: 0, flags: fn, isRepeat: false)
    #expect(events() == [.begin])
    m.secondaryHotkey = nil
    #expect(events() == [.begin, .cancel])
    // The old chord's release now means nothing.
    m.process(type: .flagsChanged, keyCode: 0, flags: [], isRepeat: false)
    #expect(events() == [.begin, .cancel])
}

// MARK: - Conflicts

@Test("A modifier-only chord shadows anything that starts with it")
func conflictDetection() {
    let fnOnly = Hotkey(keyCode: nil, modifierFlags: fn.rawValue)
    let fnSpace = Hotkey(keyCode: space, modifierFlags: fn.rawValue)
    let ctrlSemicolon = Hotkey.defaultHotkey

    #expect(Hotkey.conflict(between: fnOnly, and: fnSpace) != nil)
    #expect(Hotkey.conflict(between: fnSpace, and: fnOnly) != nil)
    #expect(Hotkey.conflict(between: fnOnly, and: fnOnly) != nil)
    #expect(Hotkey.conflict(between: fnOnly, and: ctrlSemicolon) == nil)
    #expect(Hotkey.conflict(between: fnSpace, and: ctrlSemicolon) == nil)
    // Two key chords on the same key with different modifiers are fine.
    #expect(Hotkey.conflict(between: fnSpace,
                            and: Hotkey(keyCode: space, modifierFlags: control.rawValue)) == nil)
}

// MARK: - Persistence

@MainActor
@Test("The alternate shortcut survives a round-trip and is absent by default")
func secondaryHotkeyPersists() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("clio-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }

    let store = SettingsStore(fileURL: url)
    #expect(store.settings.secondaryHotkey == nil)
    #expect(store.settings.hotkeyDisplayString == "⌃;")

    store.settings.secondaryHotkey = Hotkey(keyCode: nil, modifierFlags: fn.rawValue)
    #expect(store.settings.hotkeyDisplayString == "⌃; or fn")
    store.flush()

    let reloaded = SettingsStore(fileURL: url)
    #expect(reloaded.settings.secondaryHotkey == Hotkey(keyCode: nil, modifierFlags: fn.rawValue))
    #expect(reloaded.settings.hotkeys.count == 2)
}

@Test("A settings file from before the alternate shortcut still decodes")
func oldSettingsFileDecodes() throws {
    let json = #"{"schemaVersion":1,"hotkey":{"keyCode":41,"modifierFlags":262144},"hotkeyMode":"toggle"}"#
    let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    #expect(settings.hotkey == .defaultHotkey)
    #expect(settings.secondaryHotkey == nil)
    #expect(settings.hotkeyMode == .toggle)
}
