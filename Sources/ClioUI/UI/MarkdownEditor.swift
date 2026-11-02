import AppKit
import SwiftUI
import ClioCore

/// A notes editor that writes Markdown and shows it as it is typed:
/// headings large, bold bold, code in a monospace, ticked items struck
/// through — with the syntax itself dimmed, never hidden, so what is saved
/// is plain Markdown that reads the same in any other editor.
///
/// An `NSTextView` and not SwiftUI's `TextEditor`, which can neither style
/// its text nor be told what Return and Tab should do. Lists continue on
/// Return and end on an empty item; Tab and ⇧Tab indent them; a click on a
/// checkbox ticks it; ⌘B, ⌘I and ⌘K wrap the selection. Every edit goes
/// through the text view's own undo.
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    /// Set to focus the editor when it appears.
    var focusOnAppear = false

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    /// Never shorter than this, so there is always somewhere to click.
    var minHeight: CGFloat = 240

    // No scroll view of its own: the editor is as tall as its text and lives
    // inside the document's one scroll, which is what slides under the
    // window's glass toolbar. A scroll inside a scroll would leave nothing
    // passing under the toolbar, and scroll at cross purposes.
    func makeNSView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 20, height: 6)
        textView.font = MarkdownStyle.body
        textView.typingAttributes = MarkdownStyle.base
        textView.placeholder = placeholder
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.replaceAllText(with: text)
        MarkdownStyle.apply(to: textView.textStorage!)
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return textView
    }

    func updateNSView(_ textView: MarkdownTextView, context: Context) {
        context.coordinator.text = $text
        guard textView.string != text else { return }
        // Changed from outside — another window, a reload. Keep the caret
        // where it was as far as the new text allows.
        let selection = textView.selectedRange()
        textView.replaceAllText(with: text)
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: MarkdownTextView,
                      context: Context) -> CGSize? {
        // Only the width it is given. Asked for its ideal size, SwiftUI
        // proposes an infinite width; echoed back, the editor claimed all of
        // it, the split view shut the sidebar to make room, and the text was
        // laid out on a line no window could show.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 480
        return CGSize(width: width, height: max(minHeight, textView.height(forWidth: width)))
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            // A new line makes it taller; SwiftUI asks for the size again.
            textView.invalidateIntrinsicContentSize()
            textView.needsDisplay = true
        }

        /// Restyled after every change to the characters. Attributes only —
        /// the text is not touched, so undo is unaffected.
        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MarkdownStyle.apply(to: textStorage)
        }
    }
}

// MARK: - The text view

final class MarkdownTextView: NSTextView {
    var placeholder = ""

    /// Its own, not the window's. The window's is shared by every editor it
    /// has held, and ⌘Z after switching meetings — or after the note was
    /// reloaded from disk — replayed edits from other text into this one,
    /// with indexes that no longer fit.
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }

    /// How tall the text is at `width`, insets included.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        let lineWidth = max(1, width - 2 * textContainerInset.width)
        if textContainer.containerSize.width != lineWidth {
            textContainer.containerSize = NSSize(width: lineWidth,
                                                 height: .greatestFiniteMagnitude)
        }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer).height
        return ceil(used + 2 * textContainerInset.height)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    /// Replaces all of the text from outside — a reload, another note — and
    /// forgets the edits that were made to what it replaces.
    func replaceAllText(with text: String) {
        string = text
        ownUndoManager.removeAllActions()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerInset.height)
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: MarkdownStyle.body,
            .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    // MARK: Return and Tab

    override func insertNewline(_ sender: Any?) {
        let (line, lineRange) = currentLine()
        // Only at the end of the line; Return in the middle splits as usual.
        guard selectedRange().length == 0,
              selectedRange().location == NSMaxRange(lineRange) - trailingNewlineLength(lineRange)
        else { return super.insertNewline(sender) }
        switch MarkdownSyntax.continuation(after: line) {
        case .newline:
            super.insertNewline(sender)
        case .continueWith(let prefix):
            replace(selectedRange(), with: "\n" + prefix)
        case .endList:
            let content = NSRange(location: lineRange.location,
                                  length: lineRange.length - trailingNewlineLength(lineRange))
            replace(content, with: "")
        }
    }

    override func insertTab(_ sender: Any?) {
        guard MarkdownSyntax.isListItem(currentLine().text) else { return super.insertTab(sender) }
        indent(by: 1)
    }

    override func insertBacktab(_ sender: Any?) {
        guard MarkdownSyntax.isListItem(currentLine().text) else { return super.insertBacktab(sender) }
        indent(by: -1)
    }

    private func indent(by levels: Int) {
        let (line, range) = currentLine()
        let caret = selectedRange()
        if levels > 0 {
            replace(NSRange(location: range.location, length: 0), with: MarkdownSyntax.indent,
                    select: NSRange(location: caret.location + MarkdownSyntax.indent.count,
                                    length: caret.length))
        } else if line.hasPrefix(MarkdownSyntax.indent) {
            let width = MarkdownSyntax.indent.count
            replace(NSRange(location: range.location, length: width), with: "",
                    select: NSRange(location: max(range.location, caret.location - width),
                                    length: caret.length))
        }
    }

    // MARK: ⌘B, ⌘I, ⌘K

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "b": wrap("**")
        case "i": wrap("*")
        case "k":
            let edit = MarkdownSyntax.makeLink(string, selection: selectedRange())
            replace(edit.range, with: edit.replacement, select: edit.selection)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    private func wrap(_ marker: String) {
        let edit = MarkdownSyntax.toggleWrap(string, selection: selectedRange(), marker: marker)
        replace(edit.range, with: edit.replacement, select: edit.selection)
    }

    // MARK: Clicking a checkbox

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = characterIndex(at: point), toggleCheckbox(atCharacter: index) { return }
        super.mouseDown(with: event)
    }

    /// Ticks or unticks the checkbox `index` falls in. False if it falls in
    /// none, so the click is an ordinary one.
    func toggleCheckbox(atCharacter index: Int) -> Bool {
        guard let span = MarkdownSyntax.spans(in: string).first(where: {
            if case .checkbox = $0.kind { return NSLocationInRange(index, $0.range) }
            return false
        }) else { return false }
        let lineRange = (string as NSString).lineRange(for: span.range)
        let content = NSRange(location: lineRange.location,
                              length: lineRange.length - trailingNewlineLength(lineRange))
        guard let toggled = MarkdownSyntax.toggledCheckbox((string as NSString).substring(with: content))
        else { return false }
        replace(content, with: toggled, select: selectedRange())
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        // The pointing hand over every checkbox, so it reads as a button.
        guard let layoutManager, let textContainer else { return }
        for span in MarkdownSyntax.spans(in: string) {
            guard case .checkbox = span.kind else { continue }
            let glyphs = layoutManager.glyphRange(forCharacterRange: span.range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: inContainer, in: textContainer,
                                                 fractionOfDistanceBetweenInsertionPoints: &fraction)
        return index < (string as NSString).length ? index : nil
    }

    // MARK: Editing, undoably

    /// Replaces `range` the way typing would: undoable, announced to the
    /// delegate, restyled.
    private func replace(_ range: NSRange, with replacement: String, select: NSRange? = nil) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(select ?? NSRange(location: range.location + (replacement as NSString).length,
                                           length: 0))
        window?.invalidateCursorRects(for: self)
    }

    private func currentLine() -> (text: String, range: NSRange) {
        let ns = string as NSString
        let range = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let content = NSRange(location: range.location, length: range.length - trailingNewlineLength(range))
        return (ns.substring(with: content), range)
    }

    private func trailingNewlineLength(_ range: NSRange) -> Int {
        let ns = string as NSString
        guard range.length > 0 else { return 0 }
        return ns.substring(with: NSRange(location: NSMaxRange(range) - 1, length: 1)) == "\n" ? 1 : 0
    }
}

// MARK: - How it looks

enum MarkdownStyle {
    static let size: CGFloat = 14
    static var body: NSFont { .systemFont(ofSize: size) }

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        style.paragraphSpacing = 4
        return style
    }

    static var base: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    static func headingFont(_ level: Int) -> NSFont {
        let sizes: [CGFloat] = [24, 20, 17, 15, 14, 14]
        return .systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: .semibold)
    }

    /// Restyles all of it. Notes are short; a whole pass is simpler than
    /// working out which lines a change could have reached, and fast enough
    /// to run on every keystroke.
    static func apply(to storage: NSTextStorage) {
        let all = NSRange(location: 0, length: storage.length)
        storage.setAttributes(base, range: all)
        for span in MarkdownSyntax.spans(in: storage.string) {
            guard NSMaxRange(span.range) <= storage.length else { continue }
            switch span.kind {
            case .heading(let level):
                storage.addAttribute(.font, value: headingFont(level), range: span.range)
            case .bold:
                storage.applyFontTraits(.boldFontMask, range: span.range)
            case .italic:
                storage.applyFontTraits(.italicFontMask, range: span.range)
            case .code:
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.15),
                ], range: span.range)
            case .strikethrough:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: NSColor.secondaryLabelColor],
                                      range: span.range)
            case .linkText:
                storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: span.range)
            case .linkURL:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
                storage.applyFontTraits(.italicFontMask, range: span.range)
            case .marker:
                storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: span.range)
            case .listMarker:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
            case .checkbox(let done):
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .medium),
                    .foregroundColor: done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                ], range: span.range)
            case .doneItem:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: NSColor.secondaryLabelColor],
                                      range: span.range)
            }
        }
    }
}

#if DEBUG
// MARK: - Checking the editing, for real

extension MarkdownTextView {
    /// Drives a real text view in a real window through every editing rule —
    /// Return, Tab, ⌘B, a checkbox click, undo — and reports each. The rules
    /// themselves are unit-tested in ClioCore; this is the wiring to AppKit,
    /// which only a running view can show. CLIO_MARKDOWN_CHECK=1.
    @MainActor
    static func check() -> [String] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = MarkdownTextView(frame: window.contentView!.bounds)
        view.allowsUndo = true
        view.isRichText = false
        window.contentView?.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        var results: [String] = []

        func set(_ text: String, caret: Int? = nil) {
            if let undo = view.undoManager {
                while undo.groupingLevel > 0 { undo.endUndoGrouping() }
            }
            view.replaceAllText(with: text)
            view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        }
        func expect(_ name: String, _ actual: String, _ wanted: String) {
            let line = actual == wanted
                ? "ok    \(name)"
                : "FAIL  \(name): got \(actual.debugDescription), wanted \(wanted.debugDescription)"
            results.append(line)
            // As it happens, so a hang says where.
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        func key(_ character: String) {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: 0, windowNumber: window.windowNumber,
                                         context: nil, characters: character,
                                         charactersIgnoringModifiers: character,
                                         isARepeat: false, keyCode: 0)!
            _ = view.performKeyEquivalent(with: event)
        }

        set("- milk")
        view.insertNewline(nil)
        expect("Return continues a bullet", view.string, "- milk\n- ")
        view.insertNewline(nil)
        expect("Return on an empty bullet ends the list", view.string, "- milk\n")

        set("1. one")
        view.insertNewline(nil)
        expect("Return numbers the next item", view.string, "1. one\n2. ")

        set("- [x] done")
        view.insertNewline(nil)
        expect("Return after a ticked item starts an empty box", view.string, "- [x] done\n- [ ] ")

        set("- [ ] buy milk\n- [ ] eggs", caret: 0)
        view.insertNewline(nil)
        expect("Return mid-list splits as usual", view.string, "\n- [ ] buy milk\n- [ ] eggs")

        set("- item")
        view.insertTab(nil)
        expect("Tab indents a list item", view.string, "  - item")
        view.insertBacktab(nil)
        expect("⇧Tab outdents it", view.string, "- item")

        set("make this bold")
        view.setSelectedRange(NSRange(location: 5, length: 4))
        key("b")
        expect("⌘B wraps the selection", view.string, "make **this** bold")
        key("b")
        expect("⌘B again unwraps it", view.string, "make this bold")

        set("see docs")
        view.setSelectedRange(NSRange(location: 4, length: 4))
        key("k")
        expect("⌘K makes a link", view.string, "see [docs]()")

        set("- [ ] write notes")
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        if let layout = view.layoutManager, let container = view.textContainer {
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: 3, length: 1),
                                           actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += view.textContainerOrigin.x
            rect.origin.y += view.textContainerOrigin.y
            // The click's two halves, without NSTextView's tracking loop,
            // which would wait here for a mouse-up that never comes: where
            // the point lands, then what landing there does.
            let index = view.characterIndex(at: NSPoint(x: rect.midX, y: rect.midY))
            expect("A click in the middle of the box lands on it",
                   index.map { String($0) } ?? "nil", "3")
            _ = index.map { view.toggleCheckbox(atCharacter: $0) }
        }
        expect("A click on the box ticks it", view.string, "- [x] write notes")

        // A real ⌘Z is its own event, by which time the event's undo group
        // has closed. Here it is all one turn of the run loop, so close it.
        if let undo = view.undoManager {
            let raised = ObjCException.catching {
                while undo.groupingLevel > 0 { undo.endUndoGrouping() }
                undo.undo()
            }
            if let raised { expect("⌘Z raises nothing", raised, "") }
        }
        expect("⌘Z unticks it", view.string, "- [ ] write notes")

        window.orderOut(nil)
        return results
    }
}
#endif

#if DEBUG
/// For the app's CLIO_MARKDOWN_CHECK tool, which lives outside this module.
public enum MarkdownEditorCheck {
    @MainActor public static func run() -> [String] { MarkdownTextView.check() }
}
#endif
