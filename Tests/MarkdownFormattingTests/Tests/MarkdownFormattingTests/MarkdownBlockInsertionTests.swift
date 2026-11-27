import XCTest
@testable import MarkdownEngine

/// A quote taken from a PDF lands in the note as a block of its own.
final class MarkdownBlockInsertionTests: XCTestCase {
    private let block = "> Quote\n>\n> — [Doc, p. 2](a.pdf#page=2)"

    private func insert(into text: String, at location: Int, length: Int = 0) -> String {
        let range = NSRange(location: location, length: length)
        let inserted = MarkdownEditorController.blockInsertion(of: block, into: text, replacing: range)
        return (text as NSString).replacingCharacters(in: range, with: inserted)
    }

    func testIntoAnEmptyNoteItIsTheNote() {
        XCTAssertEqual(insert(into: "", at: 0), block + "\n")
    }

    func testAtTheEndOfAParagraphItGetsABlankLineBefore() {
        XCTAssertEqual(insert(into: "Intro", at: 5), "Intro\n\n" + block + "\n")
        XCTAssertEqual(insert(into: "Intro\n", at: 6), "Intro\n\n" + block + "\n")
    }

    func testAfterABlankLineNothingIsAdded() {
        XCTAssertEqual(insert(into: "Intro\n\n", at: 7), "Intro\n\n" + block + "\n")
    }

    func testBetweenTwoParagraphsEachSideKeepsItsBlankLine() {
        let text = "One\n\nTwo"
        XCTAssertEqual(insert(into: text, at: 5), "One\n\n" + block + "\n\nTwo")
        XCTAssertEqual(insert(into: "One\nTwo", at: 4), "One\n\n" + block + "\n\nTwo")
    }

    func testMidLineTheLineIsSplitIntoItsOwnBlocks() {
        XCTAssertEqual(insert(into: "AB", at: 1), "A\n\n" + block + "\n\nB")
    }

    func testASelectionIsReplaced() {
        XCTAssertEqual(insert(into: "Keep\n\nselected words\n\nKeep", at: 6, length: 14), "Keep\n\n" + block + "\n\nKeep")
    }
}
