import Foundation

/// Markdown as the notes editor sees it: where each piece of syntax is, and
/// what an edit should do — without drawing anything, so it can be tested.
///
/// Deliberately the Markdown people type in notes, not all of CommonMark:
/// headings, emphasis, code, strikethrough, links, quotes, lists and
/// checkboxes. The text is never rewritten to hide its syntax; the editor
/// only dims the markers, so the file stays plain Markdown that opens the
/// same anywhere.
public enum MarkdownSyntax {

    public enum Kind: Equatable, Hashable, Sendable {
        /// A whole heading line, level 1–6.
        case heading(Int)
        case bold
        case italic
        case code
        case strikethrough
        case linkText
        case linkURL
        /// A whole quoted line.
        case quote
        /// Syntax to dim: `#`, `**`, `` ` ``, `>`, a link's brackets.
        case marker
        /// A list's bullet or number.
        case listMarker
        /// `[ ]` or `[x]`.
        case checkbox(done: Bool)
        /// The text of a ticked item.
        case doneItem
        /// A line inside a fenced code block, fences excluded.
        case codeBlock
        /// A ``` line that opens or closes a code block.
        case fence
        /// `---`, `***` or `___` alone on a line.
        case rule
        /// "<!--12:40-->" at the end of a line: when in the meeting the
        /// line was written, in seconds. An HTML comment, so every other
        /// Markdown reader shows nothing there at all.
        case timeMark(seconds: Double)
    }

    public struct Span: Equatable, Sendable {
        public var kind: Kind
        /// UTF-16, as `NSString` and `NSTextStorage` count.
        public var range: NSRange

        public init(_ kind: Kind, _ range: NSRange) {
            self.kind = kind
            self.range = range
        }
    }

    // MARK: Finding the syntax

    public static func spans(in text: String) -> [Span] {
        let string = text as NSString
        var spans: [Span] = []
        var location = 0
        var inFence = false
        while location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            var content = lineRange
            // Without its line break.
            while content.length > 0,
                  let scalar = UnicodeScalar(string.character(at: NSMaxRange(content) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                content.length -= 1
            }
            let trimmed = string.substring(with: content).trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                // Fences open and close; nothing inside is Markdown.
                spans.append(Span(.fence, content))
                inFence.toggle()
            } else if inFence {
                if content.length > 0 { spans.append(Span(.codeBlock, content)) }
            } else if rule.firstMatch(in: text, range: content) != nil {
                spans.append(Span(.rule, content))
            } else {
                spans += lineSpans(string, content)
            }
            location = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
        return spans
    }

    private static func lineSpans(_ string: NSString, _ line: NSRange) -> [Span] {
        guard line.length > 0 else { return [] }
        var spans: [Span] = []
        var inlineFrom = line.location

        if let match = heading.firstMatch(in: string as String, range: line) {
            let marks = match.range(at: 1)
            spans.append(Span(.heading(marks.length), line))
            spans.append(Span(.marker, NSRange(location: marks.location,
                                               length: match.range.length - match.range(at: 2).length)))
            inlineFrom = match.range(at: 2).location
        } else if let match = checkbox.firstMatch(in: string as String, range: line) {
            let box = match.range(at: 3)
            let done = string.substring(with: box).lowercased().contains("x")
            spans.append(Span(.listMarker, match.range(at: 2)))
            spans.append(Span(.checkbox(done: done), box))
            let rest = NSRange(location: NSMaxRange(match.range), length: NSMaxRange(line) - NSMaxRange(match.range))
            if done, rest.length > 0 { spans.append(Span(.doneItem, rest)) }
            inlineFrom = rest.location
        } else if let match = listItem.firstMatch(in: string as String, range: line) {
            spans.append(Span(.listMarker, match.range(at: 2)))
            inlineFrom = NSMaxRange(match.range)
        } else if let match = quoteLine.firstMatch(in: string as String, range: line) {
            spans.append(Span(.quote, line))
            spans.append(Span(.marker, match.range(at: 1)))
            inlineFrom = NSMaxRange(match.range)
        }

        var rest = NSRange(location: inlineFrom, length: NSMaxRange(line) - inlineFrom)
        // The time the line was written, off the end, before anything
        // inline is looked for in what is left.
        if let match = timeMark.firstMatch(in: string as String, range: line),
           let seconds = seconds(string.substring(with: match.range(at: 1))) {
            spans.append(Span(.timeMark(seconds: seconds), match.range))
            rest.length = max(0, match.range.location - rest.location)
        }
        if rest.length > 0 { spans += inlineSpans(string, rest) }
        return spans
    }

    // MARK: When a line was written

    /// " <!--12:40-->" for 760 seconds into the meeting.
    public static func timeMark(_ seconds: Double) -> String {
        " <!--\(MeetingLine.timestamp(seconds))-->"
    }

    /// "12:40" or "1:04:07" as seconds; nil for anything else.
    static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").map { Double($0) }
        guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    /// The line with the time it was written added to its end — unless it
    /// has one, has nothing on it but a list marker, or is a heading: a
    /// note's title is not a moment in the meeting.
    public static func stamped(_ line: String, at seconds: Double) -> String? {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard timeMark.firstMatch(in: line, range: whole) == nil,
              heading.firstMatch(in: line, range: whole) == nil else { return nil }
        var content = line
        if let match = checkbox.firstMatch(in: line, range: whole) ?? listItem.firstMatch(in: line, range: whole) {
            content = ns.substring(from: NSMaxRange(match.range))
        }
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return line + timeMark(seconds)
    }

    /// Whether a line has nothing written on it yet — empty, or only a
    /// list marker or an empty box: what the next character typed begins.
    /// A heading is not one: it is never marked with a time.
    public static func isUnwritten(_ line: String) -> Bool {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard heading.firstMatch(in: line, range: whole) == nil,
              !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return false }
        var content = line
        if let match = checkbox.firstMatch(in: line, range: whole) ?? listItem.firstMatch(in: line, range: whole) {
            content = ns.substring(from: NSMaxRange(match.range))
        } else if ["-", "*", "+"].contains(line.trimmingCharacters(in: .whitespaces)) {
            content = ""
        }
        return content.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The notes without the times in them: for a summary's prompt, a
    /// preview, the clipboard — anywhere the notes are read as words.
    public static func withoutTimeMarks(_ text: String) -> String {
        timeMark.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                          withTemplate: "")
    }

    private static func inlineSpans(_ string: NSString, _ range: NSRange) -> [Span] {
        var spans: [Span] = []
        var taken: [NSRange] = []
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        let text = string as String

        // Code first: nothing inside it is anything else.
        for match in code.matches(in: text, range: range) {
            spans.append(Span(.code, match.range))
            spans.append(Span(.marker, NSRange(location: match.range.location, length: 1)))
            spans.append(Span(.marker, NSRange(location: NSMaxRange(match.range) - 1, length: 1)))
            taken.append(match.range)
        }
        for match in link.matches(in: text, range: range) where free(match.range) {
            let label = match.range(at: 1), url = match.range(at: 2)
            spans.append(Span(.linkText, label))
            spans.append(Span(.marker, NSRange(location: match.range.location, length: 1)))
            spans.append(Span(.marker, NSRange(location: NSMaxRange(label), length: 2)))
            spans.append(Span(.linkURL, url))
            spans.append(Span(.marker, NSRange(location: NSMaxRange(url), length: 1)))
            taken.append(match.range)
        }
        for (pattern, kind, width) in [(bold, Kind.bold, 2), (strike, .strikethrough, 2),
                                       (italicStar, .italic, 1), (italicUnderscore, .italic, 1)] {
            for match in pattern.matches(in: text, range: range) where free(match.range) {
                spans.append(Span(kind, match.range))
                spans.append(Span(.marker, NSRange(location: match.range.location, length: width)))
                spans.append(Span(.marker, NSRange(location: NSMaxRange(match.range) - width, length: width)))
                // Bold is not also two italics.
                if kind == .bold { taken.append(match.range) }
            }
        }
        return spans
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    nonisolated(unsafe) static let heading = regex(#"^(#{1,6})[ \t]+(.*)$"#)
    nonisolated(unsafe) static let rule = regex(#"^[ \t]*([-*_])[ \t]*\1[ \t]*\1[ \t-*_]*$"#)
    nonisolated(unsafe) static let checkbox = regex(#"^([ \t]*)([-*+])[ \t]+(\[[ xX]\])[ \t]"#)
    nonisolated(unsafe) static let listItem = regex(#"^([ \t]*)([-*+]|\d+[.)])[ \t]"#)
    nonisolated(unsafe) static let quoteLine = regex(#"^([ \t]*>[ \t]?)"#)
    nonisolated(unsafe) static let timeMark = regex(#"[ \t]?<!--((?:\d{1,2}:)?\d{1,2}:\d{2})-->[ \t]*$"#)
    nonisolated(unsafe) static let code = regex(#"`[^`\n]+`"#)
    nonisolated(unsafe) static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    nonisolated(unsafe) static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    nonisolated(unsafe) static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    nonisolated(unsafe) static let italicStar = regex(#"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#)
    nonisolated(unsafe) static let italicUnderscore = regex(#"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#)

    // MARK: Editing

    /// What Return does at the end of `line`.
    public enum Continuation: Equatable, Sendable {
        /// An ordinary line: just a line break.
        case newline
        /// A list goes on: a line break and this to start the next item.
        case continueWith(String)
        /// Return on an item with nothing in it ends the list: the marker
        /// goes, and the line is left empty.
        case endList
    }

    public static func continuation(after line: String) -> Continuation {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        func isEmpty(after match: NSTextCheckingResult) -> Bool {
            ns.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let m = checkbox.firstMatch(in: line, range: all) {
            if isEmpty(after: m) { return .endList }
            return .continueWith("\(ns.substring(with: m.range(at: 1)))\(ns.substring(with: m.range(at: 2))) [ ] ")
        }
        if let m = listItem.firstMatch(in: line, range: all) {
            if isEmpty(after: m) { return .endList }
            let indent = ns.substring(with: m.range(at: 1))
            let marker = ns.substring(with: m.range(at: 2))
            if let number = Int(marker.dropLast()) {
                return .continueWith("\(indent)\(number + 1)\(marker.last!) ")
            }
            return .continueWith("\(indent)\(marker) ")
        }
        if let m = quoteLine.firstMatch(in: line, range: all) {
            if isEmpty(after: m) { return .endList }
            return .continueWith(ns.substring(with: m.range(at: 1)).hasSuffix(" ")
                                 ? ns.substring(with: m.range(at: 1))
                                 : ns.substring(with: m.range(at: 1)) + " ")
        }
        return .newline
    }

    /// Typing `[]` — or `[ ]` — at the start of a line, or after a bullet,
    /// makes the line a to-do: what to put in place of everything before
    /// the caret, given that text, or nil if it is not the shortcut.
    /// "[]" → "- [ ] ", "  - []" → "  - [ ] ". The editor asks only when
    /// nothing follows the caret on the line.
    public static func todoShortcut(_ beforeCaret: String) -> String? {
        let ns = beforeCaret as NSString
        guard let m = todoTyped.firstMatch(in: beforeCaret, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let indent = ns.substring(with: m.range(at: 1))
        let bullet = m.range(at: 2).location == NSNotFound ? "-" : ns.substring(with: m.range(at: 2))
        return "\(indent)\(bullet) [ ] "
    }

    nonisolated(unsafe) static let todoTyped = regex(#"\A([ \t]*)(?:([-*+])[ \t]+)?\[ ?\]\z"#)

    /// What an empty note starts as in the editor: an empty H1, then an
    /// empty line for the text — each its own line with its own
    /// placeholder, so the caret is the heading's size on the first and the
    /// text's on the second, and ↑ ↓ go between them. Never written to the
    /// file on its own: see `isEmptyNote`.
    public static let emptyNote = "# \n"

    /// True for a note with nothing in it but the empty heading it starts
    /// with — which is saved as no notes at all.
    public static func isEmptyNote(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).allSatisfy { $0 == "#" }
    }

    /// Whether Tab on `line` should indent it rather than insert a tab.
    public static func isListItem(_ line: String) -> Bool {
        let all = NSRange(location: 0, length: (line as NSString).length)
        return listItem.firstMatch(in: line, range: all) != nil
    }

    /// One level of list indent.
    public static let indent = "  "

    /// The line with its checkbox ticked or unticked, or nil if it has none.
    public static func toggledCheckbox(_ line: String) -> String? {
        let ns = line as NSString
        guard let m = checkbox.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        let box = ns.substring(with: m.range(at: 3))
        return ns.replacingCharacters(in: m.range(at: 3), with: box == "[ ]" ? "[x]" : "[ ]")
    }

    /// ⌘B, ⌘I and the like: wraps the selection in `marker`, or unwraps it
    /// if it is already wrapped. With nothing selected, leaves the caret
    /// between a new pair. Returns the edit to make and where the selection
    /// goes after it.
    public static func toggleWrap(_ text: String, selection: NSRange, marker: String)
        -> (range: NSRange, replacement: String, selection: NSRange) {
        let ns = text as NSString
        let width = (marker as NSString).length
        let before = NSRange(location: selection.location - width, length: width)
        let after = NSRange(location: NSMaxRange(selection), length: width)
        if before.location >= 0, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == marker, ns.substring(with: after) == marker {
            let whole = NSRange(location: before.location, length: selection.length + 2 * width)
            return (whole, ns.substring(with: selection),
                    NSRange(location: before.location, length: selection.length))
        }
        let selected = ns.substring(with: selection)
        return (selection, marker + selected + marker,
                NSRange(location: selection.location + width, length: selection.length))
    }

    /// ⌘K: the selection becomes a link's text, and the caret waits where
    /// the address goes.
    public static func makeLink(_ text: String, selection: NSRange)
        -> (range: NSRange, replacement: String, selection: NSRange) {
        let selected = (text as NSString).substring(with: selection)
        let replacement = "[\(selected)]()"
        let caret = selection.location + (selected as NSString).length + 3
        return (selection, replacement, NSRange(location: caret, length: 0))
    }
}
