import XCTest
@testable import MarkdownExport

/// What the editor writes for an alignment must come out aligned in the export (and the split
/// view's preview, which shares the converter), never as the literal tag.
final class MarkdownExportTests: XCTestCase {
    func testAnAlignmentWrapperBecomesAnAlignedBlock() {
        let html = MarkdownHTML.body(from: "<div align=\"center\">\n\nCentred **text**.\n\n</div>")
        XCTAssertTrue(html.contains("<div style=\"text-align: center\">"), html)
        XCTAssertTrue(html.contains("<p>Centred <strong>text</strong>.</p>"), html)
        XCTAssertFalse(html.contains("&lt;div"), "the tag isn't shown as text")
        XCTAssertFalse(html.contains("align=\"center\""))
    }

    func testEachAlignmentHasItsOwnStyle() {
        for alignment in ["left", "center", "right", "justify"] {
            let html = MarkdownHTML.body(from: "<div align=\"\(alignment)\">\n\ntext\n\n</div>")
            XCTAssertTrue(html.contains("text-align: \(alignment)"), alignment)
        }
    }

    func testBlocksOutsideTheWrapperAreNotAligned() {
        let html = MarkdownHTML.body(from: "Before.\n\n<div align=\"right\">\n\nIn.\n\n</div>\n\nAfter.")
        let wrapped = html.components(separatedBy: "</div>")
        XCTAssertEqual(wrapped.count, 2, "one wrapper")
        XCTAssertTrue(wrapped[0].contains("In."), "inside the wrapper")
        XCTAssertFalse(wrapped[0].contains("After."), "After. is outside it")
        XCTAssertTrue(wrapped[1].contains("After."))
        // Before. comes ahead of the wrapper's opening tag.
        let before = wrapped[0].range(of: "Before.")?.lowerBound
        let open = wrapped[0].range(of: "<div")?.lowerBound
        XCTAssertNotNil(before); XCTAssertNotNil(open)
        if let before, let open { XCTAssertLessThan(before, open) }
    }

    func testTheWrapperKeepsItsSourceLineForTheSplitView() {
        let html = MarkdownHTML.body(from: "Intro.\n\n<div align=\"center\">\n\nCentred.\n\n</div>", annotated: true)
        XCTAssertTrue(html.contains("<div style=\"text-align: center\" data-line=\"2\">"), html)
        XCTAssertTrue(html.contains("data-line=\"4\""), "the inner paragraph points at its own line")
    }

    func testAnAlignmentTagInsideACodeFenceStaysCode() {
        let html = MarkdownHTML.body(from: "```\n<div align=\"center\">\n```")
        XCTAssertFalse(html.contains("text-align"))
        XCTAssertTrue(html.contains("&lt;div align"))
    }

    func testAnUnclosedWrapperStillRendersItsContent() {
        let html = MarkdownHTML.body(from: "<div align=\"center\">\n\nNever closed.")
        XCTAssertTrue(html.contains("Never closed."))
    }

    func testFormulasExportAsTheirSourceWithoutARenderer() {
        let html = MarkdownHTML.body(from: "Inline $x^2$ here.\n\n$$\nE = mc^2\n$$")
        XCTAssertTrue(html.contains("$x^2$"))
        XCTAssertTrue(html.contains("E = mc^2"))
    }

    // MARK: Typeset formulas

    /// A renderer that writes what it was asked, so what reaches it can be checked.
    private func spy(_ log: @escaping (String, Bool) -> Void) -> MarkdownHTML.MathRenderer {
        { latex, display in log(latex, display); return "<MATH display=\(display)>\(latex)</MATH>" }
    }

    func testInlineAndDisplayFormulasGoThroughTheRenderer() {
        var seen: [(String, Bool)] = []
        let html = MarkdownHTML.body(from: "Euler $e^{i\\pi}$ here.\n\n$$\n\\int_0^1 x\\,dx\n$$\n\nOne line:\n\n$$ a + b $$",
                                     math: spy { seen.append(($0, $1)) })
        XCTAssertEqual(seen.map(\.0), ["e^{i\\pi}", "\\int_0^1 x\\,dx", "a + b"])
        XCTAssertEqual(seen.map(\.1), [false, true, true])
        XCTAssertTrue(html.contains("<p>Euler <MATH display=false>e^{i\\pi}</MATH> here.</p>"), html)
        XCTAssertTrue(html.contains("<p style=\"text-align: center\"><MATH display=true>"), html)
    }

    func testTheFormulaIsHandedOverUnescapedAndKeepsItsUnderscoresAndStars() {
        var seen: [String] = []
        let html = MarkdownHTML.body(from: "Let $a_1 < b_2 * c_3$ hold.", math: spy { latex, _ in seen.append(latex) })
        XCTAssertEqual(seen, ["a_1 < b_2 * c_3"], "no &lt;, no emphasis")
        XCTAssertFalse(html.contains("<em>"), html)
    }

    func testCurrencyAndCodeAreNotFormulas() {
        var seen: [String] = []
        let html = MarkdownHTML.body(from: "It costs $5 or $6 today, `inline $x$ code` too.\n\n```\n$$\nnot math\n$$\n```",
                                     math: spy { latex, _ in seen.append(latex) })
        XCTAssertTrue(seen.isEmpty, "\(seen)")
        XCTAssertTrue(html.contains("$5 or $6"))
        XCTAssertTrue(html.contains("inline $x$ code"))
        XCTAssertTrue(html.contains("not math"))
    }

    func testAFormulaInsideAnAlignmentWrapperAndAList() {
        var seen: [String] = []
        let html = MarkdownHTML.body(from: "<div align=\"center\">\n\n$$\nx\n$$\n\n</div>\n\n- item with $y$",
                                     math: spy { latex, _ in seen.append(latex) })
        XCTAssertEqual(seen, ["x", "y"])
        XCTAssertTrue(html.contains("text-align: center"))
    }

    // MARK: The look: callouts, colour, highlights, code, scale

    func testACalloutBecomesATintedBoxWithItsTitle() {
        let html = MarkdownHTML.body(from: "> [!tip] Remember\n> Use **callouts**.\n\n> [!warning]\n> Careful.")
        XCTAssertTrue(html.contains("class=\"callout callout-tip\""), html)
        XCTAssertTrue(html.contains("<div class=\"callout-title\"><span class=\"callout-icon\">💡</span>Remember</div>"), html)
        XCTAssertTrue(html.contains("Use <strong>callouts</strong>."))
        XCTAssertTrue(html.contains("callout-warning"))
        XCTAssertTrue(html.contains(">Warning</div>"), "no title: the kind names it")
        XCTAssertFalse(html.contains("[!tip]"), "the marker isn't shown")
    }

    func testAnOrdinaryQuoteStaysAQuote() {
        let html = MarkdownHTML.body(from: "> Just a quotation.")
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertFalse(html.contains("callout"))
    }

    func testColourAndHighlightSpansPassThroughWithOnlyAHexColour() {
        let html = MarkdownHTML.body(from: "<span style=\"color: #E03E3E\">red</span> and <mark style=\"background: #FFE066\">key</mark> and ==plain==.")
        XCTAssertTrue(html.contains("<span style=\"color: #E03E3E\">red</span>"), html)
        XCTAssertTrue(html.contains("<mark style=\"background-color: #FFE066\">key</mark>"), html)
        XCTAssertTrue(html.contains("<mark>plain</mark>"), html)
        // Anything but a hex colour is shown as text, not let into the page's style.
        let hostile = MarkdownHTML.body(from: "<span style=\"color: red; background: url(x)\">x</span>")
        XCTAssertFalse(hostile.contains("<span style"), hostile)
    }

    func testCodeBlocksGoThroughTheRendererWhenThereIsOne() {
        let html = MarkdownHTML.body(from: "```swift\nlet x = 1\n```", code: { code, language in
            "<span class=\"k\">\(language):\(code)</span>"
        })
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\"><span class=\"k\">swift:let x = 1</span></code></pre>"), html)
        let plain = MarkdownHTML.body(from: "```\na < b\n```")
        XCTAssertTrue(plain.contains("a &lt; b"), "without one the code is escaped text")
    }

    func testTaskItemsCarryAClassForTheirBox() {
        let html = MarkdownHTML.body(from: "- [x] done\n- [ ] open\n- plain")
        XCTAssertTrue(html.contains("<li class=\"task done\"><span class=\"box\">☑</span>done</li>"), html)
        XCTAssertTrue(html.contains("<li class=\"task\"><span class=\"box\">☐</span>open</li>"), html)
        XCTAssertTrue(html.contains("<li>plain</li>"))
    }

    func testThePageScalesWithTheChosenSize() {
        func rootSize(_ scale: Double) -> String? {
            let page = MarkdownHTML.page(from: "x", title: "t", scale: scale)
            return page.components(separatedBy: "html { font-size: ").dropFirst().first?.components(separatedBy: "px").first
        }
        XCTAssertEqual(rootSize(1), "16.00")
        XCTAssertEqual(rootSize(1.25), "20.00")
        XCTAssertEqual(rootSize(0.75), "12.00")
    }

    func testThePageStyleHasTheNotionAndObsidianLook() {
        let page = MarkdownHTML.page(from: "x", title: "t")
        for rule in ["print-color-adjust: exact", ".callout-tip", "blockquote {", "mark {", "li.task"] {
            XCTAssertTrue(page.contains(rule), rule)
        }
    }

    // MARK: Arrows and the preview

    func testTypedArrowsBecomeArrows() {
        XCTAssertTrue(MarkdownHTML.body(from: "The First Agent -> simple").contains("Agent → simple"))
        XCTAssertTrue(MarkdownHTML.body(from: "a <- b").contains("a ← b"))
        XCTAssertTrue(MarkdownHTML.body(from: "a <-> b").contains("a ↔ b"))
        XCTAssertTrue(MarkdownHTML.body(from: "- item -> next").contains("<li>item → next</li>"), "inside a list")
        XCTAssertTrue(MarkdownHTML.body(from: "> [!tip] A -> B\n> body").contains("A → B"), "in a callout title")
        XCTAssertTrue(MarkdownHTML.body(from: "| a | b |\n| --- | --- |\n| x -> y | z |").contains("<td>x → y</td>"), "in a table")
    }

    func testArrowsAreLeftAloneInCodeAndFormulas() {
        let html = MarkdownHTML.body(from: "Use `a -> b` and $a \\to b$ and $x <- y$.\n\n```\nf -> g\n```", math: { latex, _ in "[\(latex)]" })
        XCTAssertTrue(html.contains("<code>a -&gt; b</code>"), html)
        XCTAssertTrue(html.contains("[a \\to b]") && html.contains("[x <- y]"), "formulas keep their source: \(html)")
        XCTAssertTrue(html.contains("f -&gt; g"), "a code block keeps its text")
    }

    func testThePreviewAndTheExportShareOneStylesheet() {
        let css = MarkdownHTML.stylesheet()
        XCTAssertTrue(MarkdownHTML.page(from: "x", title: "t").contains(css))
        for rule in [".callout", "mark {", "blockquote {", "li.task"] { XCTAssertTrue(css.contains(rule), rule) }
    }

    func testTheFormulasOfAListItemInAPreviewAreTypeset() {
        let html = MarkdownHTML.body(from: "- $P^{*}$ → la storia\n- $A$ → le azioni", annotated: true, math: { latex, _ in "<IMG \(latex)>" })
        XCTAssertTrue(html.contains("<IMG P^{*}> → la storia"), html)
        XCTAssertTrue(html.contains("<IMG A> → le azioni"), html)
        XCTAssertFalse(html.contains("$"), "no dollar signs are left in the preview")
    }

    func testTheRendererIsOnlyForTheCallThatGaveIt() {
        _ = MarkdownHTML.body(from: "$x$", math: { _, _ in "IMG" })
        XCTAssertTrue(MarkdownHTML.body(from: "$x$").contains("$x$"), "a later call without one writes source")
    }
}
