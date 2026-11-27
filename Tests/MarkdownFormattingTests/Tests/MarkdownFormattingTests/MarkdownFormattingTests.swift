import XCTest
@testable import MarkdownEngine

/// What an edit leaves: the new text, and the text the selection then covers.
private struct Result {
    let text: String
    let selected: String
    let caret: Int
}

private func applied(_ edit: MarkdownSourceEdit?, on text: String, file: StaticString = #filePath, line: UInt = #line) -> Result? {
    guard let edit else { return nil }
    let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) as NSString
    XCTAssertLessThanOrEqual(NSMaxRange(edit.selection), result.length, "selection inside the text", file: file, line: line)
    return Result(text: result as String, selected: result.substring(with: edit.selection), caret: edit.selection.location)
}

/// The range of the first occurrence of `needle`, as a selection.
private func select(_ needle: String, in text: String) -> NSRange {
    (text as NSString).range(of: needle)
}

private func caret(at marker: String, in text: String) -> NSRange {
    NSRange(location: (text as NSString).range(of: marker).location, length: 0)
}

final class InlineMathTests: XCTestCase {
    private func toggle(_ text: String, _ selection: NSRange) -> Result? {
        applied(MarkdownSourceFormatting.toggleInlineMath(in: text as NSString, selection: selection), on: text)
    }

    func testAnEmptySelectionInsertsAPairWithTheCaretBetween() throws {
        let text = "Energy is  here."
        let r = try XCTUnwrap(toggle(text, NSRange(location: 10, length: 0)))
        XCTAssertEqual(r.text, "Energy is $$ here.")
        XCTAssertEqual(r.caret, 11)
    }

    func testASelectionIsWrappedAndStaysSelected() throws {
        let text = "Euler: e^{i\\pi} + 1 = 0 holds."
        let r = try XCTUnwrap(toggle(text, select("e^{i\\pi} + 1 = 0", in: text)))
        XCTAssertEqual(r.text, "Euler: $e^{i\\pi} + 1 = 0$ holds.")
        XCTAssertEqual(r.selected, "e^{i\\pi} + 1 = 0")
    }

    func testSpacesAroundTheSelectionStayOutsideTheDelimiters() throws {
        let text = "a  x^2  b"
        let r = try XCTUnwrap(toggle(text, NSRange(location: 1, length: 7)))   // "  x^2  "
        XCTAssertEqual(r.text, "a  $x^2$  b")
        XCTAssertEqual(r.selected, "x^2")
    }

    func testASelectionOfOnlySpaceInsertsAnEmptyPair() throws {
        let r = try XCTUnwrap(toggle("a   b", NSRange(location: 1, length: 3)))
        XCTAssertEqual(r.text, "a$$b")
        XCTAssertEqual(r.caret, 2)
    }

    func testAppliedAgainToTheWrappedFormulaItUnwraps() throws {
        let wrapped = "see $x^2$ now"
        let inside = try XCTUnwrap(toggle(wrapped, select("x^2", in: wrapped)))
        XCTAssertEqual(inside.text, "see x^2 now")
        XCTAssertEqual(inside.selected, "x^2")
        let including = try XCTUnwrap(toggle(wrapped, select("$x^2$", in: wrapped)))
        XCTAssertEqual(including.text, "see x^2 now")
        XCTAssertEqual(including.selected, "x^2")
    }

    func testInlineMathNextToADisplayFenceIsNotMistakenForAPair() throws {
        // The `$` either side belong to `$$…$$`: wrapping adds a pair, it doesn't strip them.
        let text = "$$x$$"
        let r = try XCTUnwrap(toggle(text, select("x", in: text)))
        XCTAssertEqual(r.text, "$$$x$$$")
    }

    func testASelectionAcrossLinesIsLeftAlone() {
        let text = "one\ntwo"
        XCTAssertNil(toggle(text, NSRange(location: 0, length: 7)))
    }

    func testTheEditIsASingleReplacementOfTheSelection() throws {
        let text = "a b c"
        let edit = try XCTUnwrap(MarkdownSourceFormatting.toggleInlineMath(in: text as NSString, selection: NSRange(location: 2, length: 1)))
        XCTAssertEqual(edit.range, NSRange(location: 2, length: 1))
        XCTAssertEqual(edit.replacement, "$b$")
    }

    func testInsertionAtTheEndAndStartOfTheText() throws {
        XCTAssertEqual(try XCTUnwrap(toggle("", NSRange(location: 0, length: 0))).text, "$$")
        XCTAssertEqual(try XCTUnwrap(toggle("x", NSRange(location: 0, length: 1))).text, "$x$")
        XCTAssertEqual(try XCTUnwrap(toggle("x", NSRange(location: 1, length: 0))).text, "x$$")
    }

    func testMultibyteTextKeepsTheSelectionOnTheFormula() throws {
        let text = "così α + β = γ ✓"
        let r = try XCTUnwrap(toggle(text, select("α + β = γ", in: text)))
        XCTAssertEqual(r.text, "così $α + β = γ$ ✓")
        XCTAssertEqual(r.selected, "α + β = γ")
    }
}

final class DisplayMathTests: XCTestCase {
    private func toggle(_ text: String, _ selection: NSRange) -> Result? {
        applied(MarkdownSourceFormatting.toggleDisplayMath(in: text as NSString, selection: selection), on: text)
    }

    func testAnEmptyDocumentGetsABlockWithTheCaretOnItsBlankLine() throws {
        let r = try XCTUnwrap(toggle("", NSRange(location: 0, length: 0)))
        XCTAssertEqual(r.text, "$$\n\n$$")
        XCTAssertEqual(r.caret, 3)
    }

    func testABlankLineBetweenParagraphsBecomesTheBlock() throws {
        let text = "Before.\n\n\n\nAfter."
        let r = try XCTUnwrap(toggle(text, NSRange(location: 9, length: 0)))        // the second blank line
        XCTAssertTrue(r.text.contains("\n$$\n\n$$\n"))
        XCTAssertTrue(r.text.hasPrefix("Before.\n\n"))
        XCTAssertTrue(r.text.hasSuffix("After."))
        XCTAssertEqual(r.caret, (r.text as NSString).range(of: "$$\n").location + 3)
    }

    func testAWholeSelectedLineBecomesTheFormula() throws {
        let text = "Intro.\n\nx^2 + y^2 = z^2\n\nOutro."
        let r = try XCTUnwrap(toggle(text, select("x^2 + y^2 = z^2", in: text)))
        XCTAssertEqual(r.text, "Intro.\n\n$$\nx^2 + y^2 = z^2\n$$\n\nOutro.")
        XCTAssertEqual(r.selected, "x^2 + y^2 = z^2")
    }

    func testASelectionInTheMiddleOfALineSplitsTheLineAroundTheBlock() throws {
        let text = "The value E = mc^2 is famous."
        let r = try XCTUnwrap(toggle(text, select("E = mc^2", in: text)))
        XCTAssertEqual(r.text, "The value\n\n$$\nE = mc^2\n$$\n\nis famous.")
        XCTAssertEqual(r.selected, "E = mc^2")
    }

    func testABlockNextToTextWithNoBlankLineGetsOne() throws {
        let text = "Line one\nx = 1\nLine three"
        let r = try XCTUnwrap(toggle(text, select("x = 1", in: text)))
        XCTAssertEqual(r.text, "Line one\n\n$$\nx = 1\n$$\n\nLine three")
    }

    func testABlockAtTheEndOfTheTextAddsNoTrailingBreak() throws {
        let text = "Intro.\n\nf(x)"
        let r = try XCTUnwrap(toggle(text, select("f(x)", in: text)))
        XCTAssertEqual(r.text, "Intro.\n\n$$\nf(x)\n$$")
    }

    func testAMultiLineSelectionKeepsItsLines() throws {
        let text = "a &= b \\\\\nc &= d"
        let r = try XCTUnwrap(toggle(text, NSRange(location: 0, length: (text as NSString).length)))
        XCTAssertEqual(r.text, "$$\n" + text + "\n$$")
        XCTAssertEqual(r.selected, text)
    }

    func testAppliedToTheFormulaOrItsBlockItUnwraps() throws {
        let text = "Intro.\n\n$$\nx^2\n$$\n\nOutro."
        let inside = try XCTUnwrap(toggle(text, select("x^2", in: text)))
        XCTAssertEqual(inside.text, "Intro.\n\nx^2\n\nOutro.")
        let caret = try XCTUnwrap(toggle(text, NSRange(location: (text as NSString).range(of: "x^2").location + 1, length: 0)))
        XCTAssertEqual(caret.text, "Intro.\n\nx^2\n\nOutro.")
        let whole = try XCTUnwrap(toggle(text, select("$$\nx^2\n$$", in: text)))
        XCTAssertEqual(whole.text, "Intro.\n\nx^2\n\nOutro.")
    }

    func testTwoBlocksArePairedInOrderSoTheSecondIsNotMistakenForAnOpening() throws {
        let text = "$$\na\n$$\n\ntext\n\n$$\nb\n$$"
        let second = try XCTUnwrap(toggle(text, select("b", in: text)))
        XCTAssertEqual(second.text, "$$\na\n$$\n\ntext\n\nb")
        let first = try XCTUnwrap(toggle(text, select("a", in: text)))
        XCTAssertEqual(first.text, "a\n\ntext\n\n$$\nb\n$$")
    }

    func testTextBetweenBlocksIsNotInsideEither() throws {
        let text = "$$\na\n$$\n\ntext\n\n$$\nb\n$$"
        // Outside both: it wraps, it doesn't unwrap one of them.
        let r = try XCTUnwrap(toggle(text, select("text", in: text)))
        XCTAssertEqual(r.text, "$$\na\n$$\n\n$$\ntext\n$$\n\n$$\nb\n$$")
    }

    func testUnwrappingKeepsTheLineBreakAfterTheBlock() throws {
        let text = "$$\nx\n$$\nnext"
        let r = try XCTUnwrap(toggle(text, select("x", in: text)))
        XCTAssertEqual(r.text, "x\nnext")
    }
}

final class AlignmentPersistenceTests: XCTestCase {
    private func align(_ alignment: MarkdownTextAlignment, _ text: String, _ selection: NSRange) -> Result? {
        applied(MarkdownSourceFormatting.setAlignment(alignment, in: text as NSString, selection: selection), on: text)
    }

    func testCenterWrapsTheParagraphInAPortableDivThatReadsBackAsCentered() throws {
        let text = "Intro.\n\nA centred line.\n\nOutro."
        let r = try XCTUnwrap(align(.center, text, select("centred", in: text)))
        XCTAssertEqual(r.text, "Intro.\n\n<div align=\"center\">\n\nA centred line.\n\n</div>\n\nOutro.")

        // "Saved and reopened" is the same text: the alignment is read back from the source.
        let regions = MarkdownAlignmentStyling.regions(in: r.text as NSString)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.alignment, .center)
        let body = (r.text as NSString).substring(with: try XCTUnwrap(regions.first).body)
        XCTAssertTrue(body.contains("A centred line."))
    }

    func testRightAndLeftRoundTrip() throws {
        var text = "Only paragraph."
        text = try XCTUnwrap(align(.right, text, NSRange(location: 3, length: 0))).text
        XCTAssertEqual(MarkdownAlignmentStyling.regions(in: text as NSString).first?.alignment, .right)

        // Changing the alignment changes the wrapper's, it doesn't nest another.
        text = try XCTUnwrap(align(.center, text, select("Only", in: text))).text
        XCTAssertEqual(MarkdownAlignmentStyling.regions(in: text as NSString).map(\.alignment), [.center])
        XCTAssertEqual(text.components(separatedBy: "<div").count - 1, 1)

        // Left is the absence of a wrapper.
        text = try XCTUnwrap(align(.left, text, select("Only", in: text))).text
        XCTAssertEqual(text.trimmingCharacters(in: .whitespacesAndNewlines), "Only paragraph.")
        XCTAssertTrue(MarkdownAlignmentStyling.regions(in: text as NSString).isEmpty)
    }

    func testTheInnerMarkdownStaysUntouchedByAlignment() throws {
        let text = "**bold** and `code` and $x^2$"
        let r = try XCTUnwrap(align(.center, text, NSRange(location: 2, length: 0)))
        XCTAssertTrue(r.text.contains(text))
    }

    func testAlignmentDoesNotApplyInsideFencedCode() {
        let text = "```\ncode line\n```"
        XCTAssertNil(align(.center, text, select("code line", in: text)))
    }

    func testAFormulaBlockAlignsAsABlockAndStaysAFormula() throws {
        let text = "Intro.\n\n$$\nx^2\n$$\n\nOutro."
        let r = try XCTUnwrap(align(.right, text, select("x^2", in: text)))
        XCTAssertEqual(MarkdownAlignmentStyling.regions(in: r.text as NSString).first?.alignment, .right)
        XCTAssertTrue(r.text.contains("$$\nx^2\n$$"))
    }
}
