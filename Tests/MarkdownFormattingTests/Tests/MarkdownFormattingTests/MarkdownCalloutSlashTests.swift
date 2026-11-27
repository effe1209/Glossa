import AppKit
import XCTest
@testable import MarkdownEngine

private func applied(_ edit: MarkdownSourceEdit?, to text: String) -> (text: String, caret: Int)? {
    guard let edit else { return nil }
    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    return (result, edit.selection.location)
}

final class CalloutInsertTests: XCTestCase {
    private func callout(_ kind: String, _ text: String, _ selection: NSRange) -> (text: String, caret: Int)? {
        applied(MarkdownSourceFormatting.insertCallout(kind: kind, in: text as NSString, selection: selection), to: text)
    }

    func testABlankLineBecomesAnEmptyCalloutWithTheCaretInItsBody() throws {
        let r = try XCTUnwrap(callout("tip", "", NSRange(location: 0, length: 0)))
        XCTAssertEqual(r.text, "> [!tip]\n> ")
        XCTAssertEqual(r.caret, r.text.utf16.count)
    }

    func testAParagraphBecomesTheCalloutsBody() throws {
        let text = "Intro.\n\nWatch the edge.\n\nOutro."
        let r = try XCTUnwrap(callout("warning", text, (text as NSString).range(of: "edge")))
        XCTAssertEqual(r.text, "Intro.\n\n> [!warning]\n> Watch the edge.\n\nOutro.")
    }

    func testSeveralSelectedLinesAreAllQuoted() throws {
        let text = "one\ntwo\nthree"
        let r = try XCTUnwrap(callout("note", text, NSRange(location: 0, length: text.utf16.count)))
        XCTAssertEqual(r.text, "> [!note]\n> one\n> two\n> three")
    }

    func testAQuoteBecomesACalloutWithoutQuotingItTwice() throws {
        let text = "> already quoted\n> second"
        let r = try XCTUnwrap(callout("info", text, NSRange(location: 3, length: 0)))
        XCTAssertEqual(r.text, "> [!info]\n> already quoted\n> second")
    }

    func testACalloutChangesKindInsteadOfNesting() throws {
        let text = "> [!tip] Title\n> body"
        let r = try XCTUnwrap(callout("danger", text, (text as NSString).range(of: "body")))
        XCTAssertEqual(r.text, "> [!danger] Title\n> body")
        XCTAssertEqual(r.text.components(separatedBy: "[!").count - 1, 1)
    }

    func testTheKindIsReducedToLetters() throws {
        XCTAssertEqual(try XCTUnwrap(callout("Wa rn!ing", "", NSRange(location: 0, length: 0))).text, "> [!warning]\n> ")
        XCTAssertNil(callout("123", "x", NSRange(location: 0, length: 0)))
    }

    func testEveryOfferedKindIsKnownToTheTheme() {
        for kind in MarkdownCallout.kinds {
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil), "symbol \(kind.symbol)")
            _ = MarkdownEditorTheme.calloutColor(for: kind.id)
        }
        XCTAssertEqual(Set(MarkdownCallout.kinds.map(\.id)).count, MarkdownCallout.kinds.count)
    }
}

final class SlashMatchTests: XCTestCase {
    private func titles(_ query: String) -> [String] { SlashCommand.matches(for: query).map(\.title) }

    func testNothingTypedListsEveryCommand() {
        XCTAssertEqual(titles("").count, SlashCommand.all.count)
        XCTAssertTrue(titles("").contains("Heading 1"))
        XCTAssertTrue(titles("").contains("Callout: Tip"))
    }

    func testTypingNarrowsByTitleAndKeywords() {
        XCTAssertEqual(titles("head"), ["Heading 1", "Heading 2", "Heading 3"])
        XCTAssertEqual(titles("h2"), ["Heading 2"])
        XCTAssertEqual(titles("todo").first, nil, "'todo' is a keyword of the To-do list only as 'task' or 'checkbox'")
        XCTAssertEqual(titles("task"), ["To-do list"])
        XCTAssertTrue(titles("latex").contains("Inline math"))
        XCTAssertTrue(titles("latex").contains("Display math"))
    }

    func testEveryWordMustMatch() {
        XCTAssertEqual(titles("callout tip"), ["Callout: Tip"])
        XCTAssertEqual(titles("math in"), ["Inline math"])
        XCTAssertTrue(titles("xyz").isEmpty)
    }

    func testTitleMatchesComeFirstAndCaseDoesNotMatter() {
        let found = titles("CODE")
        XCTAssertEqual(found.first, "Code block", "its title starts with the query; the Callout rows only list it as a keyword")
        XCTAssertTrue(titles("quote").first == "Quote")
    }

    func testCommandsCoverTheBlocksAWriterReachesFor() {
        let all = Set(titles(""))
        for name in ["Text", "Heading 1", "Bulleted list", "Numbered list", "To-do list", "Quote", "Code block", "Table", "Divider",
                     "Inline math", "Display math"] {
            XCTAssertTrue(all.contains(name), name)
        }
        XCTAssertEqual(MarkdownCallout.kinds.count, all.filter { $0.hasPrefix("Callout: ") }.count)
    }
}

/// Enter inside a quote: a list there goes on as a list.
@MainActor
final class QuoteListContinuationTests: XCTestCase {
    /// Types a line break at the end of `text` and returns what the editor then holds.
    private func enter(after text: String) -> String {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = text
        let end = (text as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        let handled = !MarkdownLists.handleInsertion(textView: view, affectedCharRange: NSRange(location: end, length: 0), replacementString: "\n")
        if !handled { view.insertText("\n", replacementRange: NSRange(location: end, length: 0)) }
        return view.string
    }

    func testABulletInsideAQuoteGoesOnAsABullet() {
        XCTAssertEqual(enter(after: "> - Sensori"), "> - Sensori\n> - ")
        XCTAssertEqual(enter(after: "> * star"), "> * star\n> * ")
    }

    func testANumberedItemInsideAQuoteCountsUp() {
        XCTAssertEqual(enter(after: "> 1. first"), "> 1. first\n> 2. ")
        XCTAssertEqual(enter(after: "> 9. ninth"), "> 9. ninth\n> 10. ")
    }

    func testAChecklistItemInsideAQuoteComesBackUnchecked() {
        XCTAssertEqual(enter(after: "> - [x] done"), "> - [x] done\n> - [ ] ")
        XCTAssertEqual(enter(after: "> 1. [ ] todo"), "> 1. [ ] todo\n> 2. [ ] ")
    }

    func testAnEmptyBulletEndsTheListButStaysInTheQuote() {
        XCTAssertEqual(enter(after: "> - Sensori\n> - "), "> - Sensori\n> ")
    }

    func testANestedQuoteKeepsItsMarkers() {
        XCTAssertEqual(enter(after: ">> - deep"), ">> - deep\n>> - ")
    }

    func testAPlainQuoteLineAndAPlainListAreAsBefore() {
        XCTAssertEqual(enter(after: "> just text"), "> just text\n> ")
        XCTAssertEqual(enter(after: "- item"), "- item\n- ")
        XCTAssertEqual(enter(after: "> "), "")
    }

    func testAListInTheQuoteKeepsItsIndent() {
        XCTAssertEqual(enter(after: ">   - indented"), ">   - indented\n>   - ")
    }
}

/// Typing "<" then "-" makes the left arrow, as "-" then ">" makes the right one.
@MainActor
final class TypedArrowTests: XCTestCase {
    private func type(_ character: String, after text: String) -> String {
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.string = text
        let end = (text as NSString).length
        view.setSelectedRange(NSRange(location: end, length: 0))
        if MarkdownLists.handleInsertion(textView: view, affectedCharRange: NSRange(location: end, length: 0), replacementString: character) {
            view.insertText(character, replacementRange: NSRange(location: end, length: 0))
        }
        return view.string
    }

    func testLessThanThenDashIsALeftArrow() {
        XCTAssertEqual(type("-", after: "x <"), "x ←")
    }

    func testDashThenGreaterThanIsStillARightArrow() {
        XCTAssertEqual(type(">", after: "x -"), "x →")
    }

    func testAnOrdinaryDashIsUntouched() {
        XCTAssertEqual(type("-", after: "a"), "a-")
        XCTAssertEqual(type("-", after: ""), "-")
        XCTAssertEqual(type("-", after: "a -"), "a --")
    }
}
