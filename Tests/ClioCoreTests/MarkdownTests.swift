import Testing
import Foundation
@testable import ClioCore

@Suite("Markdown in notes")
struct MarkdownTests {
    /// The text each span of `kind` covers.
    private func text(_ kind: MarkdownSyntax.Kind, in source: String) -> [String] {
        MarkdownSyntax.spans(in: source)
            .filter { $0.kind == kind }
            .map { (source as NSString).substring(with: $0.range) }
    }

    @Test("Headings, with their marks dimmed, at every level")
    func headings() {
        let source = "# Title\n### Next steps\nnot # a heading"
        #expect(text(.heading(1), in: source) == ["# Title"])
        #expect(text(.heading(3), in: source) == ["### Next steps"])
        #expect(text(.marker, in: source).prefix(2) == ["# ", "### "])
    }

    @Test("Bold, italic, code, strikethrough and links, inline")
    func inline() {
        let source = "a **bold** and *it* and _it2_ and `x*y*` and ~~gone~~ and [site](https://a.b)"
        #expect(text(.bold, in: source) == ["**bold**"])
        #expect(text(.italic, in: source) == ["*it*", "_it2_"])
        #expect(text(.code, in: source) == ["`x*y*`"])          // nothing styled inside code
        #expect(text(.strikethrough, in: source) == ["~~gone~~"])
        #expect(text(.linkText, in: source) == ["site"])
        #expect(text(.linkURL, in: source) == ["https://a.b"])
    }

    @Test("Snake_case and a lone asterisk are not emphasis")
    func notEmphasis() {
        #expect(text(.italic, in: "call my_var_name, 2 * 3 * 4").isEmpty)
    }

    @Test("Lists, numbers, checkboxes and quotes are found; a ticked item is marked done")
    func blocks() {
        let source = "- one\n  * two\n3. three\n- [ ] todo\n- [x] done it\n> quoted"
        #expect(text(.listMarker, in: source) == ["-", "*", "3.", "-", "-"])
        #expect(text(.checkbox(done: false), in: source) == ["[ ]"])
        #expect(text(.checkbox(done: true), in: source) == ["[x]"])
        #expect(text(.doneItem, in: source) == ["done it"])
        #expect(text(.quote, in: source) == ["> quoted"])
    }

    @Test("A fenced code block is code, fences and all; nothing inside it is Markdown")
    func codeBlocks() {
        let source = "before\n```swift\nlet x = **not bold**\n# not a heading\n```\nafter **bold**"
        #expect(text(.fence, in: source) == ["```swift", "```"])
        #expect(text(.codeBlock, in: source) == ["let x = **not bold**", "# not a heading"])
        #expect(text(.bold, in: source) == ["**bold**"])
        #expect(text(.heading(1), in: source).isEmpty)
    }

    @Test("A line of three dashes, stars or underscores is a rule; a list item is not")
    func rules() {
        let source = "---\n* * *\n___\n- item\n--"
        #expect(text(.rule, in: source) == ["---", "* * *", "___"])
        #expect(text(.listMarker, in: source) == ["-"])
    }

    @Test("An empty note's starting heading counts as no notes")
    func emptyNote() {
        #expect(MarkdownSyntax.isEmptyNote(MarkdownSyntax.emptyNote))
        #expect(MarkdownSyntax.isEmptyNote(""))
        #expect(MarkdownSyntax.isEmptyNote("#"))
        #expect(MarkdownSyntax.isEmptyNote("# \n\n  "))
        #expect(!MarkdownSyntax.isEmptyNote("# Plan\n"))
        #expect(!MarkdownSyntax.isEmptyNote("# \nmilk"))
    }

    @Test("[] at the start of a line makes a to-do")
    func todoShortcut() {
        #expect(MarkdownSyntax.todoShortcut("[]") == "- [ ] ")
        #expect(MarkdownSyntax.todoShortcut("[ ]") == "- [ ] ")
        #expect(MarkdownSyntax.todoShortcut("  []") == "  - [ ] ")
        #expect(MarkdownSyntax.todoShortcut("- []") == "- [ ] ")
        #expect(MarkdownSyntax.todoShortcut("  * [ ]") == "  * [ ] ")
        // Only at the start of a line, and only the brackets.
        #expect(MarkdownSyntax.todoShortcut("see []") == nil)
        #expect(MarkdownSyntax.todoShortcut("[x]") == nil)
        #expect(MarkdownSyntax.todoShortcut("- [ ] []") == nil)
        #expect(MarkdownSyntax.todoShortcut("1. []") == nil)
    }

    @Test("Return keeps a list going, numbers it, and ends it on an empty item")
    func continuation() {
        #expect(MarkdownSyntax.continuation(after: "- milk") == .continueWith("- "))
        #expect(MarkdownSyntax.continuation(after: "  * nested") == .continueWith("  * "))
        #expect(MarkdownSyntax.continuation(after: "9. ninth") == .continueWith("10. "))
        #expect(MarkdownSyntax.continuation(after: "- [x] done") == .continueWith("- [ ] "))
        #expect(MarkdownSyntax.continuation(after: "> said") == .continueWith("> "))
        #expect(MarkdownSyntax.continuation(after: "- ") == .endList)
        #expect(MarkdownSyntax.continuation(after: "- [ ] ") == .endList)
        #expect(MarkdownSyntax.continuation(after: "plain text") == .newline)
    }

    @Test("A checkbox ticks and unticks; a line without one is left alone")
    func checkboxes() {
        #expect(MarkdownSyntax.toggledCheckbox("- [ ] write notes") == "- [x] write notes")
        #expect(MarkdownSyntax.toggledCheckbox("  - [X] done") == "  - [ ] done")
        #expect(MarkdownSyntax.toggledCheckbox("- just a bullet") == nil)
    }

    @Test("⌘B wraps the selection, a second ⌘B unwraps it, and with nothing selected the caret sits inside")
    func wrapping() {
        let text = "make this bold"
        let first = MarkdownSyntax.toggleWrap(text, selection: NSRange(location: 5, length: 4), marker: "**")
        #expect(first.replacement == "**this**")
        let wrapped = (text as NSString).replacingCharacters(in: first.range, with: first.replacement)
        #expect(wrapped == "make **this** bold")
        #expect((wrapped as NSString).substring(with: first.selection) == "this")

        let second = MarkdownSyntax.toggleWrap(wrapped, selection: first.selection, marker: "**")
        #expect((wrapped as NSString).replacingCharacters(in: second.range, with: second.replacement) == text)

        let empty = MarkdownSyntax.toggleWrap("ab", selection: NSRange(location: 1, length: 0), marker: "*")
        #expect(empty.replacement == "**")
        #expect(empty.selection == NSRange(location: 2, length: 0))
    }

    @Test("⌘K makes the selection a link and leaves the caret where the address goes")
    func links() {
        let edit = MarkdownSyntax.makeLink("see docs", selection: NSRange(location: 4, length: 4))
        #expect(edit.replacement == "[docs]()")
        #expect(edit.selection == NSRange(location: 11, length: 0))
    }
}
