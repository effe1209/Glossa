import AppKit
import XCTest
@testable import MarkdownEngine
@testable import MarkdownEngineCodeBlocks

private func select(_ needle: String, in text: String) -> NSRange { (text as NSString).range(of: needle) }

private func applied(_ edit: MarkdownSourceEdit?, to text: String) -> (text: String, selected: String)? {
    guard let edit else { return nil }
    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
    return (result as String, result.substring(with: edit.selection))
}

final class ColorSourceTests: XCTestCase {
    private func color(_ hex: String?, _ kind: MarkdownColorKind, _ text: String, _ selection: NSRange) -> (text: String, selected: String)? {
        applied(MarkdownSourceFormatting.setColor(hex, kind: kind, in: text as NSString, selection: selection), to: text)
    }

    func testASelectionIsWrappedInAColourSpanAndStaysSelected() throws {
        let text = "Make this red please."
        let r = try XCTUnwrap(color("#E03E3E", .text, text, select("this red", in: text)))
        XCTAssertEqual(r.text, "Make <span style=\"color: #E03E3E\">this red</span> please.")
        XCTAssertEqual(r.selected, "this red")
    }

    func testAHighlightIsAMarkWithABackground() throws {
        let text = "A key phrase here."
        let r = try XCTUnwrap(color("#ffe066", .highlight, text, select("key phrase", in: text)))
        XCTAssertEqual(r.text, "A <mark style=\"background: #FFE066\">key phrase</mark> here.")
        XCTAssertEqual(r.selected, "key phrase")
    }

    func testAnotherColourChangesTheSpanInsteadOfNestingOne() throws {
        let text = "Say <span style=\"color: #E03E3E\">hello</span> now."
        let r = try XCTUnwrap(color("#2F80ED", .text, text, select("hello", in: text)))
        XCTAssertEqual(r.text, "Say <span style=\"color: #2F80ED\">hello</span> now.")
        XCTAssertEqual(r.selected, "hello")
        XCTAssertEqual(r.text.components(separatedBy: "<span").count - 1, 1)
    }

    func testTheSameColourAgainOrNilTakesItOff() throws {
        let text = "Say <span style=\"color: #E03E3E\">hello</span> now."
        let same = try XCTUnwrap(color("#E03E3E", .text, text, select("hello", in: text)))
        XCTAssertEqual(same.text, "Say hello now.")
        let none = try XCTUnwrap(color(nil, .text, text, select("hello", in: text)))
        XCTAssertEqual(none.text, "Say hello now.")
        XCTAssertEqual(none.selected, "hello")
        // The caret alone inside the span is enough to change or remove it.
        let caret = NSRange(location: select("ell", in: text).location, length: 0)
        XCTAssertEqual(try XCTUnwrap(color(nil, .text, text, caret)).text, "Say hello now.")
    }

    func testTheSpanSelectedWholeIsRemoved() throws {
        let text = "Say <mark style=\"background: #FFE066\">hello</mark> now."
        let r = try XCTUnwrap(color(nil, .highlight, text, select("<mark style=\"background: #FFE066\">hello</mark>", in: text)))
        XCTAssertEqual(r.text, "Say hello now.")
    }

    func testTextColourAndHighlightCanBeUsedTogether() throws {
        var text = "Both on this."
        text = try XCTUnwrap(color("#E03E3E", .text, text, select("this", in: text))).text
        let inner = select("this", in: text)
        text = try XCTUnwrap(color("#FFE066", .highlight, text, inner)).text
        XCTAssertTrue(text.contains("<span style=\"color: #E03E3E\">"))
        XCTAssertTrue(text.contains("<mark style=\"background: #FFE066\">this</mark>"))
        // Taking the highlight off leaves the colour.
        text = try XCTUnwrap(color(nil, .highlight, text, select("this", in: text))).text
        XCTAssertFalse(text.contains("<mark"))
        XCTAssertTrue(text.contains("<span style=\"color: #E03E3E\">this</span>"))
    }

    func testNothingToColourDoesNothing() {
        XCTAssertNil(color("#E03E3E", .text, "text", NSRange(location: 2, length: 0)), "no selection")
        XCTAssertNil(color("#E03E3E", .text, "one\ntwo", NSRange(location: 0, length: 7)), "across lines")
        XCTAssertNil(color(nil, .text, "plain text", select("plain", in: "plain text")), "no colour to remove")
    }

    func testASpanIsOnlyFoundOnItsOwnLine() {
        let text = "<span style=\"color: #E03E3E\">one\ntwo</span>"
        XCTAssertNil(MarkdownSourceFormatting.colorSpan(of: .text, containing: select("two", in: text), in: text as NSString))
    }

    func testColourSurvivesAsPlainTextSoSavingAndReopeningKeepsIt() throws {
        let text = "Make this red."
        let coloured = try XCTUnwrap(color("#E03E3E", .text, text, select("this", in: text))).text
        // The file is exactly that text; reading it back finds the same span.
        let span = try XCTUnwrap(MarkdownSourceFormatting.colorSpan(of: .text, containing: select("this", in: coloured), in: coloured as NSString))
        XCTAssertEqual(span.hex, "#E03E3E")
        XCTAssertEqual((coloured as NSString).substring(with: span.content), "this")
    }
}

final class ColorStylingTests: XCTestCase {
    private let hidden = NSFont.systemFont(ofSize: 1)

    private func style(_ text: String) -> [StyledRange] {
        MarkdownColorStyling.applying(to: [], text: text, hiddenFont: hidden)
    }

    func testTheWordsTakeTheColourAndTheTagsAreHidden() throws {
        let text = "a <span style=\"color: #E03E3E\">red</span> b"
        let ranges = style(text)
        let content = try XCTUnwrap(ranges.first { ($0.0 as NSRange) == select("red", in: text) })
        XCTAssertNotNil(content.1[.foregroundColor] as? NSColor)
        let tags = ranges.filter { $0.1[.foregroundColor] as? NSColor == .clear }
        XCTAssertEqual(tags.count, 2, "both tags hidden")
        XCTAssertTrue(tags.allSatisfy { ($0.1[.font] as? NSFont) == hidden })
    }

    /// Only edited paragraphs are restyled, so a tag shown while the caret was inside would stay shown
    /// after it left. They are never shown.
    func testTheTagsAreHiddenInAQuoteAndAListToo() {
        let text = "> Possiede:\n> - <mark style=\"background: #FFE066\">Sensori</mark> → x\n> - <mark style=\"background: #FECACA\">Attuatori</mark> → y"
        let ranges = style(text)
        XCTAssertEqual(ranges.filter { $0.1[.foregroundColor] as? NSColor == .clear }.count, 4, "both spans, both tags")
        XCTAssertTrue(ranges.filter { $0.1[.foregroundColor] as? NSColor == .clear }.allSatisfy { ($0.1[.font] as? NSFont) == hidden })
    }

    func testAHighlightPaintsTheBackgroundWithDarkText() throws {
        let text = "x <mark style=\"background: #FFE066\">key</mark> y"
        let ranges = style(text)
        let content = try XCTUnwrap(ranges.first { ($0.0 as NSRange) == select("key", in: text) })
        XCTAssertNotNil(content.1[.backgroundColor] as? NSColor)
        XCTAssertEqual(content.1[.foregroundColor] as? NSColor, .black)
    }

    func testTagsInCodeAreLeftAlone() {
        XCTAssertTrue(style("```\n<span style=\"color: #E03E3E\">x</span>\n```").isEmpty, "fenced")
        XCTAssertTrue(style("`<span style=\"color: #E03E3E\">x</span>`").isEmpty, "inline code")
    }

    func testAnUnclosedTagIsIgnored() {
        XCTAssertTrue(style("<span style=\"color: #E03E3E\">never closed").isEmpty)
    }

    func testANoteWithoutColoursCostsNothing() {
        let sentinel: [StyledRange] = [(NSRange(location: 0, length: 1), [.foregroundColor: NSColor.red])]
        XCTAssertEqual(MarkdownColorStyling.applying(to: sentinel, text: "plain **text**", hiddenFont: hidden).count, 1)
    }
}

final class PseudoCodeTests: XCTestCase {
    private func colour(of word: String, in code: String, _ result: NSAttributedString) -> NSColor? {
        result.attribute(.foregroundColor, at: (code as NSString).range(of: word).location, effectiveRange: nil) as? NSColor
    }

    func testKeywordsStringsNumbersCommentsAndCallsAreColoured() {
        let code = "for i in 1 to 10\n  if ok then print(\"hi\")  # note\nend"
        let out = PseudoCodeHighlighter.highlight(code)
        XCTAssertEqual(out.length, (code as NSString).length, "the styler needs the same length")
        for word in ["for", "in", "if", "then", "end"] { XCTAssertNotNil(colour(of: word, in: code, out), word) }
        XCTAssertNotNil(colour(of: "10", in: code, out))
        XCTAssertNotNil(colour(of: "\"hi\"", in: code, out))
        XCTAssertNotNil(colour(of: "# note", in: code, out))
        XCTAssertNotNil(colour(of: "print", in: code, out), "a call")
        XCTAssertNil(colour(of: "ok", in: code, out), "an ordinary name stays plain")
    }

    func testStringsAndCommentsAreNotReadAsCode() {
        let code = "x = \"if for while\" // return 42"
        let out = PseudoCodeHighlighter.highlight(code)
        let string = colour(of: "\"if for while\"", in: code, out)
        XCTAssertEqual(colour(of: "if", in: code, out), string, "keywords inside a string take the string's colour")
        let comment = colour(of: "// return 42", in: code, out)
        XCTAssertEqual(colour(of: "return", in: code, out), comment)
        XCTAssertEqual(colour(of: "42", in: code, out), comment)
    }

    func testDigitsInsideAWordAreNotANumber() {
        let code = "value2 = x1"
        let out = PseudoCodeHighlighter.highlight(code)
        XCTAssertNil(colour(of: "2", in: code, out))
    }

    func testAnUnlabeledFenceIsColouredByTheBridge() {
        let bridge = HighlighterSwiftBridge()
        XCTAssertNotNil(bridge.highlight(code: "if x then return 1", language: nil))
        XCTAssertNotNil(bridge.highlight(code: "if x then return 1", language: ""))
        XCTAssertNotNil(bridge.highlight(code: "if x then return 1", language: "pseudocode"), "a name highlight.js doesn't know")
        XCTAssertNil(bridge.highlight(code: "graph TD; A-->B", language: "mermaid"), "a diagram isn't coloured as code")
    }
}

final class CalloutColourTests: XCTestCase {
    func testEachKindHasItsColourAndUnknownKindsAreNotes() {
        let note = MarkdownEditorTheme.calloutColor(for: "note")
        XCTAssertEqual(MarkdownEditorTheme.calloutColor(for: "mystery"), note)
        for kind in ["tip", "warning", "danger", "success", "info", "question", "example", "quote"] {
            XCTAssertNotEqual(MarkdownEditorTheme.calloutColor(for: kind), note, kind)
        }
        XCTAssertEqual(MarkdownEditorTheme.calloutColor(for: "WARNING"), MarkdownEditorTheme.calloutColor(for: "warning"), "any case")
        XCTAssertEqual(MarkdownEditorTheme.calloutColor(for: "error"), MarkdownEditorTheme.calloutColor(for: "danger"), "kinds that share one")
    }
}
