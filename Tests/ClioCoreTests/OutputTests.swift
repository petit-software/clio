import Testing
import AppKit
@testable import ClioCore

/// Clipboard behaviour, on a private pasteboard.
///
/// Never `.general`: these assert what happens to the clipboard, and running
/// them must not walk off with whatever the developer had copied.
@MainActor
@Suite("Output")
struct OutputTests {

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("clio.test.\(UUID().uuidString)"))
    }

    @Test("Copy-only leaves the transcript on the clipboard")
    func copyOnlyKeepsIt() async {
        let pasteboard = scratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("something the user had", forType: .string)

        await TextInjector.inject("dictated words", action: .copyOnly,
                                  method: .paste, pasteboard: pasteboard)

        #expect(pasteboard.string(forType: .string) == "dictated words")
    }

    @Test("An empty transcript never touches the clipboard")
    func emptyTranscriptIsIgnored() async {
        let pasteboard = scratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("untouched", forType: .string)

        let result = await TextInjector.inject("", action: .copyOnly,
                                               method: .paste, pasteboard: pasteboard)

        #expect(pasteboard.string(forType: .string) == "untouched")
        if case .copiedOnly = result {} else { Issue.record("expected copiedOnly") }
    }

    @Test("Typing leaves the clipboard alone unless asked to keep it")
    func typingDoesNotStealTheClipboard() async {
        // Typing needs no clipboard at all. It used to copy regardless, which
        // silently replaced what the user had for no reason.
        let pasteboard = scratchPasteboard()
        pasteboard.clearContents()
        pasteboard.setString("something the user had", forType: .string)

        await TextInjector.inject("dictated words", action: .copyOnly,
                                  method: .typeCharacters, pasteboard: pasteboard)
        // copyOnly copies by definition; the interesting case is the flag.
        #expect(pasteboard.string(forType: .string) == "dictated words")
    }

    @Test("A snapshot restores every representation, not just the text")
    func snapshotRestoresRichContent() {
        let pasteboard = scratchPasteboard()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        item.setString("<b>rich</b>", forType: .html)
        pasteboard.writeObjects([item])

        let snapshot = TextInjector.Snapshot.capture(from: pasteboard)
        TextInjector.copy("transcript", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "transcript")

        snapshot.restore(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "plain")
        // Restoring only the string would quietly downgrade a rich copy.
        #expect(pasteboard.string(forType: .html) == "<b>rich</b>")
    }
}

// MARK: - Overlay positions

@Suite("Overlay position")
struct OverlayPositionTests {

    @Test("Every corner is offered, in reading order")
    func cornersExist() {
        let labels = OverlayPosition.allCases.map(\.label)
        #expect(labels == ["Hidden", "Top left", "Top center", "Top right",
                           "Bottom left", "Bottom center", "Bottom right",
                           "Near cursor"])
    }

    @Test("Stored values survive, so a saved position is not lost")
    func rawValuesAreStable() {
        // These strings are in every existing settings.json.
        #expect(OverlayPosition(rawValue: "topCenter") == .topCenter)
        #expect(OverlayPosition(rawValue: "bottomCenter") == .bottomCenter)
        #expect(OverlayPosition(rawValue: "nearCursor") == .nearCursor)
        // Spelled out: the left side is an Optional, so a bare `.none` binds
        // to Optional.none — nil — and the assertion would compare the case
        // against nothing at all.
        #expect(OverlayPosition(rawValue: "none") == OverlayPosition.none)
    }

    @Test("An unknown position falls back rather than wiping the settings")
    func unknownPositionFallsBack() throws {
        let json = #"{"overlayPosition":"someFuturePosition","maxRecordingSeconds":42}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(settings.overlayPosition == Settings().overlayPosition)
        #expect(settings.maxRecordingSeconds == 42)
    }
}

// MARK: - Pill size

@Suite("Pill size")
struct PillSizeTests {

    @Test("Three sizes, the default first, at the multiples the labels promise")
    func sizesAreWhatTheySay() {
        #expect(PillSize.allCases == [.regular, .large, .extraLarge])
        #expect(PillSize.allCases.map(\.scale) == [1, 1.25, 1.5])
        #expect(PillSize.allCases.map(\.label) == ["Default", "1.25×", "1.5×"])
        #expect(Settings().pillSize == .regular)
    }

    @Test("Stored values survive, so a saved size is not lost")
    func rawValuesAreStable() {
        #expect(PillSize(rawValue: "regular") == .regular)
        #expect(PillSize(rawValue: "large") == .large)
        #expect(PillSize(rawValue: "extraLarge") == .extraLarge)
    }

    @Test("Round-trips through the settings file")
    func roundTrips() throws {
        var settings = Settings()
        settings.pillSize = .extraLarge
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.pillSize == .extraLarge)
    }

    @Test("A file without the key, or with a size this version lacks, keeps the default")
    func missingOrUnknownSizeFallsBack() throws {
        let missing = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        #expect(missing.pillSize == .regular)

        let json = #"{"pillSize":"gigantic","maxRecordingSeconds":42}"#
        let unknown = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(unknown.pillSize == .regular)
        #expect(unknown.maxRecordingSeconds == 42)
    }
}
