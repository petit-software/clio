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
    /// Set, an empty note starts as an empty H1 line and an empty line
    /// under it (`MarkdownSyntax.emptyNote`): this is the H1's placeholder,
    /// `placeholder` the text's. Each is its own line, so the caret is sized
    /// to it and ↑ ↓ move between them. Nothing is written until something
    /// is typed.
    var placeholderHeading: String = ""
    /// Set to focus the editor when it appears.
    var focusOnAppear = false
    /// False for a summary or a dictation: rendered, selectable, not typed in.
    var isEditable = true

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, startsWithHeading: startsWithHeading)
    }

    private var startsWithHeading: Bool { isEditable && !placeholderHeading.isEmpty }

    /// Never shorter than this, so there is always somewhere to click.
    var minHeight: CGFloat = 240

    // No scroll view of its own: the editor is as tall as its text and lives
    // inside the document's one scroll, which is what slides under the
    // window's glass toolbar. A scroll inside a scroll would leave nothing
    // passing under the toolbar, and scroll at cross purposes.
    func makeNSView(context: Context) -> MarkdownTextView {
        let textView = MarkdownTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
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
        textView.placeholderHeading = placeholderHeading
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.prepareMarkdown()
        if startsWithHeading, text.isEmpty {
            textView.replaceAllText(with: MarkdownSyntax.emptyNote)
            // On the heading, after its hidden "# ".
            textView.setSelectedRange(NSRange(location: 2, length: 0))
        } else {
            textView.replaceAllText(with: text)
        }
        if focusOnAppear, isEditable {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return textView
    }

    func updateNSView(_ textView: MarkdownTextView, context: Context) {
        context.coordinator.text = $text
        guard textView.string != text else { return }
        // Nothing saved, and the editor showing the empty heading it starts
        // with: the same note.
        if startsWithHeading, text.isEmpty, MarkdownSyntax.isEmptyNote(textView.string) { return }
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let startsWithHeading: Bool

        init(text: Binding<String>, startsWithHeading: Bool) {
            self.text = text
            self.startsWithHeading = startsWithHeading
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // The empty heading a note starts with is no notes, not "# ".
            text.wrappedValue = startsWithHeading && MarkdownSyntax.isEmptyNote(textView.string)
                ? "" : textView.string
            // A new line makes it taller; SwiftUI asks for the size again.
            textView.invalidateIntrinsicContentSize()
            textView.needsDisplay = true
        }
    }
}

// MARK: - The text view

final class MarkdownTextView: NSTextView, @preconcurrency NSLayoutManagerDelegate {
    var placeholder = ""
    var placeholderHeading = ""
    /// What `MarkdownStyle` asked to be drawn in place of hidden syntax.
    private var decorations: [MarkdownStyle.Decoration] = []
    /// The line whose syntax shows, while editing.
    private var revealedLine: NSRange?

    /// Hooks up the hiding of syntax and styles what is there. Called once
    /// the view is made.
    func prepareMarkdown() {
        layoutManager?.delegate = self
        restyle()
    }

    /// The line being edited shows its syntax; nothing does when the editor
    /// is not being typed in — or cannot be.
    private var currentRevealedLine: NSRange? {
        guard isEditable, window?.firstResponder === self else { return nil }
        return (string as NSString).lineRange(for: NSRange(location: selectedRange().location, length: 0))
    }

    func restyle() {
        guard let textStorage else { return }
        revealedLine = currentRevealedLine
        decorations = MarkdownStyle.apply(to: textStorage, revealing: revealedLine)
        typingAttributes = MarkdownStyle.base
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func didChangeText() {
        super.didChangeText()
        restyle()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Moving to another line hides this one's syntax and shows that one's.
        if !stillSelecting, currentRevealedLine != revealedLine { restyle() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { restyle() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { DispatchQueue.main.async { [weak self] in self?.restyle() } }
        return resigned
    }

    // MARK: Hiding syntax

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes: UnsafePointer<Int>,
                       font: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = layoutManager.textStorage else { return 0 }
        var changed: [NSLayoutManager.GlyphProperty]?
        for index in 0..<glyphRange.length {
            let character = characterIndexes[index]
            guard character < storage.length,
                  storage.attribute(MarkdownStyle.hidden, at: character, effectiveRange: nil) != nil
            else { continue }
            if changed == nil { changed = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length)) }
            changed![index] = .null
        }
        guard let changed else { return 0 }
        layoutManager.setGlyphs(glyphs, properties: changed, characterIndexes: characterIndexes,
                                font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    // MARK: Drawing what is hidden

    private func rect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer, NSMaxRange(range) <= (string as NSString).length
        else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        return rect
    }

    /// Where the text's baseline is on the line holding `range`, in the
    /// view's coordinates.
    private func baseline(for range: NSRange) -> CGFloat? {
        guard let layoutManager, range.location < (string as NSString).length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY + layoutManager.location(forGlyphAt: glyph).y + textContainerOrigin.y
    }

    private func drawDecorations() {
        guard let layoutManager else { return }
        for decoration in decorations {
            switch decoration {
            case .bullet(let range):
                // A dash, not a dot: a list in notes reads as one written by
                // hand. Drawn as a short bar half the x-height over the
                // text's baseline, so it sits on the middle of the letters;
                // a character centred in the line's box sat low.
                guard let rect = rect(for: range), let baseline = baseline(for: range) else { continue }
                let font = MarkdownStyle.body
                let width = (font.pointSize * 0.5).rounded()
                let thickness: CGFloat = 1.5
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: rect.midX - width / 2,
                                                 y: baseline - font.xHeight / 2 - thickness / 2,
                                                 width: width, height: thickness),
                             xRadius: thickness / 2, yRadius: thickness / 2).fill()
            case .checkbox(let range, let done):
                guard let rect = rect(for: range) else { continue }
                // A circle: filled in the accent with the tick cut out when
                // done, an outline when not. The 24-point box the glyphs
                // are drawn on, a little taller than the text, centred in
                // the room the hidden "[ ]" leaves.
                let side = min(rect.height, MarkdownStyle.size * 1.25)
                let box = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2,
                                 width: side, height: side)
                guard let context = NSGraphicsContext.current?.cgContext else { continue }
                context.saveGState()
                context.translateBy(x: box.minX, y: box.minY)
                context.scaleBy(x: side / 24, y: side / 24)
                context.addPath((done ? LibraryIcon.todoDone : LibraryIcon.todoOpen).path.cgPath)
                context.setFillColor((done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).cgColor)
                context.fillPath(using: .evenOdd)
                context.restoreGState()
            case .rule(let range):
                let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
                var line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                line.origin.x += textContainerOrigin.x
                line.origin.y += textContainerOrigin.y
                NSColor.separatorColor.setFill()
                NSRect(x: line.minX + (textContainer?.lineFragmentPadding ?? 0), y: line.midY.rounded(),
                       width: line.width - 2 * (textContainer?.lineFragmentPadding ?? 0), height: 1).fill()
            }
        }
    }

    /// Its own, not the window's. The window's is shared by every editor it
    /// has held, and ⌘Z after switching meetings — or after the note was
    /// reloaded from disk — replayed edits from other text into this one,
    /// with indexes that no longer fit.
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }

    /// How tall the text would be at `width`, insets included — measured on
    /// a copy, laid out by a layout manager of its own.
    ///
    /// Never on the real container. SwiftUI asks at several widths, a
    /// near-zero one for the minimum among them, and whichever it asked
    /// last was the width the text was then drawn at: typing laid it out a
    /// character to a line in a column a point wide — the editor grew, and
    /// nothing could be read. The real container follows the view's width
    /// and nothing else.
    func height(forWidth width: CGFloat) -> CGFloat {
        guard let textStorage else { return 0 }
        let lineWidth = max(1, width - 2 * textContainerInset.width)
        let copy = NSTextStorage(attributedString: textStorage)
        let manager = NSLayoutManager()
        manager.delegate = self   // hides syntax as the real one does
        let container = NSTextContainer(size: NSSize(width: lineWidth,
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = textContainer?.lineFragmentPadding ?? 5
        manager.addTextContainer(container)
        copy.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height + 2 * textContainerInset.height)
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height(forWidth: bounds.width))
    }

    /// Replaces all of the text from outside — a reload, another note — and
    /// forgets the edits that were made to what it replaces.
    func replaceAllText(with text: String) {
        string = text
        ownUndoManager.removeAllActions()
        restyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawDecorations()
        drawPlaceholders()
    }

    /// The grey words on an empty note: the heading's on an H1 line with
    /// nothing typed on it, the text's on the line under it while nothing
    /// follows. Set on each line's own baseline, in its own font, so they
    /// sit where the typing will.
    private func drawPlaceholders() {
        let ns = string as NSString
        let attributes: (NSFont) -> [NSAttributedString.Key: Any] = {
            [.font: $0, .foregroundColor: NSColor.placeholderTextColor]
        }
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0)
        guard ns.length > 0 else {
            guard !placeholder.isEmpty else { return }
            (placeholder as NSString).draw(at: NSPoint(x: x, y: textContainerOrigin.y),
                                           withAttributes: attributes(MarkdownStyle.body))
            return
        }
        guard !placeholderHeading.isEmpty, let layoutManager else { return }
        let first = ns.lineRange(for: NSRange(location: 0, length: 0))
        let heading = ns.substring(with: first).trimmingCharacters(in: .whitespacesAndNewlines)
        guard heading.allSatisfy({ $0 == "#" }), heading.hasPrefix("#") else { return }
        let headingFont = MarkdownStyle.headingFont(heading.count)
        if let baseline = baseline(for: NSRange(location: 0, length: 1)) {
            (placeholderHeading as NSString).draw(
                at: NSPoint(x: x, y: baseline - headingFont.ascender),
                withAttributes: attributes(headingFont))
        }
        // The text's line: the one after the heading, while nothing is
        // written anywhere below it.
        let rest = ns.substring(from: NSMaxRange(first))
        guard !placeholder.isEmpty, ns.substring(with: first).hasSuffix("\n"),
              rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let body = MarkdownStyle.body
        let y: CGFloat
        if rest.isEmpty {
            y = layoutManager.extraLineFragmentRect.minY + textContainerOrigin.y
        } else if let baseline = baseline(for: NSRange(location: NSMaxRange(first), length: 1)) {
            y = baseline - body.ascender
        } else { return }
        (placeholder as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes(body))
    }

    // MARK: Typing

    /// `[]` at the start of a line — or after a bullet — makes it a to-do
    /// the moment the bracket closes, as long as nothing follows on the line.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string
        guard typed == "]", selectedRange().length == 0 else { return }
        let ns = self.string as NSString
        let caret = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let after = ns.substring(with: NSRange(location: caret, length: NSMaxRange(line) - caret))
        guard after.trimmingCharacters(in: .newlines).isEmpty else { return }
        let before = NSRange(location: line.location, length: caret - line.location)
        guard let todo = MarkdownSyntax.todoShortcut(ns.substring(with: before)) else { return }
        replace(before, with: todo)
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

    /// Characters with this are given no glyph: Markdown syntax, still in
    /// the text — so the file, Copy and undo all see Markdown — but not on
    /// the page. `MarkdownTextView` is the layout manager's delegate that
    /// reads it.
    static let hidden = NSAttributedString.Key("ClioMarkdownHidden")

    /// Something drawn in place of hidden syntax.
    enum Decoration: Equatable {
        case bullet(NSRange)
        case checkbox(NSRange, done: Bool)
        case rule(NSRange)
    }

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

    /// Restyles all of it, and says what to draw. Syntax is hidden except on
    /// the line `revealing` touches — the one being edited — where it shows,
    /// dimmed, so it can still be changed. Notes are short; a whole pass is
    /// simpler than working out what an edit could reach, and fast enough
    /// for every keystroke.
    @discardableResult
    static func apply(to storage: NSTextStorage, revealing: NSRange? = nil) -> [Decoration] {
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        defer { storage.endEditing() }
        storage.setAttributes(base, range: all)
        let string = storage.string as NSString
        var decorations: [Decoration] = []

        func revealed(_ range: NSRange) -> Bool {
            guard let revealing else { return false }
            let line = string.lineRange(for: range)
            return NSIntersectionRange(line, revealing).length > 0
                || (revealing.length == 0 && NSLocationInRange(revealing.location, line))
                || (revealing.length == 0 && revealing.location == NSMaxRange(line)
                    && !string.substring(with: line).hasSuffix("\n"))
        }
        func hide(_ range: NSRange) {
            guard range.length > 0 else { return }
            storage.addAttribute(hidden, value: true, range: range)
        }
        func dim(_ range: NSRange) {
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: range)
        }

        let spans = MarkdownSyntax.spans(in: storage.string)
        // A checkbox line's bullet goes with the box: "- [ ] x" shows as ☐ x.
        let boxes = spans.compactMap { span -> NSRange? in
            if case .checkbox = span.kind { return span.range }
            return nil
        }

        for span in spans {
            guard NSMaxRange(span.range) <= storage.length else { continue }
            let shown = revealed(span.range)
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
                shown ? dim(span.range) : hide(span.range)
            case .quote:
                storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: span.range)
                storage.applyFontTraits(.italicFontMask, range: span.range)
            case .marker:
                // A heading with nothing typed on it yet keeps its "# "
                // hidden on the caret's line too: the placeholder stands
                // where the words will, and "#" in front of it read as junk.
                let line = string.lineRange(for: span.range)
                let after = string.substring(with: NSRange(location: NSMaxRange(span.range),
                                                           length: NSMaxRange(line) - NSMaxRange(span.range)))
                let emptyLine = after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                shown && !emptyLine ? dim(span.range) : hide(span.range)
            case .listMarker:
                let marker = string.substring(with: span.range)
                let box = boxes.first { $0.location > span.range.location
                    && string.lineRange(for: $0) == string.lineRange(for: span.range) }
                if shown {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                         range: span.range)
                } else if let box {
                    hide(NSRange(location: span.range.location,
                                 length: box.location - span.range.location))
                } else if ["-", "*", "+"].contains(marker) {
                    // Kept for its width, and drawn over as a bullet.
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: span.range)
                    decorations.append(.bullet(span.range))
                } else {
                    // A number: the dash's grey, medium, and with digits of
                    // one width so 9. and 10. take the same room.
                    storage.addAttributes([
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
                    ], range: span.range)
                }
            case .checkbox(let done):
                storage.addAttribute(.font,
                                     value: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
                                     range: span.range)
                if shown {
                    storage.addAttribute(.foregroundColor,
                                         value: done ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
                                         range: span.range)
                } else {
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: span.range)
                    decorations.append(.checkbox(span.range, done: done))
                }
            case .doneItem:
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: NSColor.secondaryLabelColor],
                                      range: span.range)
            case .codeBlock:
                storage.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                    .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.15),
                ], range: span.range)
            case .fence:
                shown ? dim(span.range) : hide(span.range)
            case .rule:
                if shown {
                    dim(span.range)
                } else {
                    hide(span.range)
                    decorations.append(.rule(span.range))
                }
            }
        }
        return decorations
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
        view.prepareMarkdown()
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

        func type(_ characters: String) {
            for character in characters {
                view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        set("milk\n")
        type("[]")
        expect("[] makes a to-do", view.string, "milk\n- [ ] ")
        type("eggs")
        expect("…and typing goes on after the box", view.string, "milk\n- [ ] eggs")
        set("- ")
        type("[ ]")
        expect("[ ] after a bullet makes it a to-do", view.string, "- [ ] ")
        set("see ")
        type("[]")
        expect("[] mid-line stays brackets", view.string, "see []")

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
extension MarkdownTextView {
    /// For CLIO_TYPE: types into whichever notes editor has the keyboard,
    /// the way keystrokes would, and says what the text system made of it.
    @MainActor
    public static func typeIntoFocused(_ text: String) {
        func find(_ view: NSView) -> MarkdownTextView? {
            if let editor = view as? MarkdownTextView, editor.isEditable { return editor }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        let focused = NSApp.keyWindow?.firstResponder as? MarkdownTextView
        guard let view = focused ?? NSApp.keyWindow?.contentView.flatMap(find) else {
            FileHandle.standardError.write(Data("[type] no notes editor in the window\n".utf8))
            return
        }
        if focused == nil {
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        for character in text {
            if character == "\n" {
                view.insertNewline(nil)
            } else {
                view.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        }
        report(view, "typed")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            report(view, "after save")
        }
    }

    @MainActor
    private static func report(_ view: MarkdownTextView, _ when: String) {
        let storage = view.textStorage!
        let layout = view.layoutManager!
        layout.ensureLayout(for: view.textContainer!)
        var report = "[type] \(when): \(view.string.count) characters, frame \(view.frame.size)\n"
        for index in 0..<min(storage.length, 6) {
            let attributes = storage.attributes(at: index, effectiveRange: nil)
            let glyph = layout.glyphIndexForCharacter(at: index)
            let property = layout.propertyForGlyph(at: glyph)
            report += "[type]   \(index): hidden \(attributes[MarkdownStyle.hidden] != nil), "
                + "color \(String(describing: attributes[.foregroundColor])), null \(property.contains(.null))\n"
        }
        report += "[type] used \(layout.usedRect(for: view.textContainer!)), container \(view.textContainer!.containerSize)\n"
        FileHandle.standardError.write(Data(report.utf8))
    }
}

/// For the app's CLIO_MARKDOWN_CHECK tool, which lives outside this module.
public enum MarkdownEditorCheck {
    @MainActor public static func run() -> [String] { MarkdownTextView.check() }
}
#endif
