import CoreText
import PDFKit
import XCTest
@testable import PDFCitation

// MARK: Helpers

private let id = "3fa9c1d2e4b50a77"

private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("citation-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.resolvingSymlinksInPath()
}

/// A PDF with one page per string, each drawn as text so PDFKit can extract it.
@discardableResult
private func makePDF(at url: URL, pages: [String], size: CGSize = CGSize(width: 612, height: 792)) -> URL {
    var box = CGRect(origin: .zero, size: size)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for text in pages {
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: text, attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

private func registry(scoped: Bool = false) -> PDFDocumentRegistry {
    let suite = "pdfcitation.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return PDFDocumentRegistry(defaults: defaults, scoped: scoped)
}

private let paper = ["Attention is all you need. The dominant sequence transduction models are based on recurrent networks.",
                     "Second page about the model architecture and training."]

// MARK: Link format

final class PDFCitationFormatTests: XCTestCase {
    private func citation(quote: String = "The extracted text.", path: String = "Papers/doc.pdf", title: String = "Doc") -> PDFCitation {
        PDFCitation(title: title, page: 12, path: path, documentID: id, quote: quote)
    }

    func testAQuoteIsAQuoteWithItsAttributionAndLink() {
        let text = citation().markdown()
        XCTAssertEqual(text, "> The extracted text.\n>\n> — [Doc, p. 12](Papers/doc.pdf#page=12&gid=\(id)&q=The%20extracted%20text.)\n")
    }

    func testTheLinkIsAnOrdinaryPDFPageLinkTheAppAlreadyFollows() throws {
        let link = try XCTUnwrap(URL(string: citation().target))
        XCTAssertEqual(link.pathExtension, "pdf")
        XCTAssertEqual(PDFPageLink.pageIndex(in: link.fragment), 11, "existing helper reads page=12 as page index 11")
    }

    func testLinesOfAPDFAreJoinedAndHyphenationIsHealed() {
        XCTAssertEqual(PDFCitation.normalizedQuote("The model is trans-\nformed by\nthe   encoder."), ["The model is transformed by the encoder."])
        XCTAssertEqual(PDFCitation.normalizedQuote("A well-\nKnown thing"), ["A well- Known thing"], "a hyphen before a capital stays")
        XCTAssertEqual(PDFCitation.normalizedQuote("First paragraph.\n\nSecond one."), ["First paragraph.", "", "Second one."])
        XCTAssertEqual(PDFCitation.normalizedQuote("  \n \n"), [])
    }

    func testTextThatLooksLikeMarkupStaysText() {
        XCTAssertEqual(PDFCitation.escapingBlockMarkup("# not a heading"), "\\# not a heading")
        XCTAssertEqual(PDFCitation.escapingBlockMarkup("- not a list"), "\\- not a list")
        XCTAssertEqual(PDFCitation.escapingBlockMarkup("12. not numbered"), "12\\. not numbered")
        XCTAssertEqual(PDFCitation.escapingBlockMarkup("Plain 12. text"), "Plain 12. text")
        XCTAssertTrue(citation(quote: "# Chapter\n\n1. first").markdown().contains("> \\# Chapter"))
    }

    func testTheTitleCannotBreakTheLink() {
        let text = citation(title: "A [draft] of x").markdown()
        XCTAssertTrue(text.contains("[A \\[draft\\] of x, p. 12](Papers/doc.pdf"), text)
    }

    func testThePathIsEncodedSoSpacesAndParenthesesDoNotEndTheLink() throws {
        let text = citation(path: "My Papers/Smith (2020).pdf").markdown()
        XCTAssertTrue(text.contains("(My%20Papers/Smith%20%282020%29.pdf#page=12"), text)
        let refs = PDFCitation.references(in: text)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].reference.path, "My Papers/Smith (2020).pdf")
    }

    func testTheSnippetIsWholeWordsAndBounded() {
        let long = String(repeating: "word ", count: 40)
        let snippet = PDFCitation.snippet(of: long)
        XCTAssertLessThanOrEqual(snippet.count, PDFCitation.snippetLength)
        XCTAssertTrue(snippet.hasSuffix("word"))
        XCTAssertEqual(PDFCitation.snippet(of: "short"), "short")
        XCTAssertEqual(PDFCitation.snippet(of: "a\n\nb"), "a", "the first paragraph")
    }

    func testReservedCharactersInTheSnippetSurviveTheLink() throws {
        let c = citation(quote: "Fish & chips #1 = 50% off (really)?")
        let link = try XCTUnwrap(URL(string: c.target))
        let reference = try XCTUnwrap(PDFCitation.Reference(link: link))
        XCTAssertEqual(reference.snippet, "Fish & chips #1 = 50% off (really)?")
        XCTAssertEqual(reference.page, 12)
        XCTAssertEqual(reference.documentID, id)
    }

    func testAnUnicodeQuoteRoundTrips() throws {
        let c = citation(quote: "Perché «l’identità» è già lì — naïve 数学")
        let reference = try XCTUnwrap(PDFCitation.Reference(link: XCTUnwrap(URL(string: c.target))))
        XCTAssertEqual(reference.snippet, "Perché «l’identità» è già lì — naïve 数学")
    }
}

// MARK: Exact range

final class PDFCitationRangeTests: XCTestCase {
    func testTheRangeTravelsInTheLink() throws {
        let c = PDFCitation(title: "D", page: 3, path: "a.pdf", documentID: id, quote: "Hello world", range: NSRange(location: 120, length: 340))
        XCTAssertTrue(c.target.hasSuffix("&r=120-340"), c.target)
        let r = try XCTUnwrap(PDFCitation.Reference(link: XCTUnwrap(URL(string: c.target))))
        XCTAssertEqual(r.range, NSRange(location: 120, length: 340))
        XCTAssertNil(PDFCitation(title: "D", page: 3, path: "a.pdf", documentID: id, quote: "x").target.range(of: "&r="))
    }

    func testABadRangeIsIgnoredNotFatal() throws {
        for bad in ["r=-1-5", "r=4", "r=a-b", "r=3-0", "r=1-2-3"] {
            let r = try XCTUnwrap(PDFCitation.Reference(path: "a.pdf", fragment: "page=1&gid=\(id)&\(bad)"))
            XCTAssertNil(r.range, bad)
        }
    }

    /// What the app does at click time: the recorded range gives back the very words quoted.
    func testTheRangeSelectsTheQuotedWordsOnAPage() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = makePDF(at: dir.appendingPathComponent("r.pdf"), pages: ["Alpha beta gamma delta epsilon zeta."])
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let text = try XCTUnwrap(page.string) as NSString
        let range = text.range(of: "gamma delta")
        let selection = try XCTUnwrap(page.selection(for: range))
        XCTAssertEqual(selection.string, "gamma delta")
        XCTAssertEqual(selection.numberOfTextRanges(on: page) > 0, true)
        let first = selection.range(at: 0, on: page)
        XCTAssertEqual(first, range)
    }
}

// MARK: Reading links

final class PDFCitationReadingTests: XCTestCase {
    private func reference(_ link: String) -> PDFCitation.Reference? { URL(string: link).flatMap(PDFCitation.Reference.init(link:)) }

    func testAWellFormedLinkIsRead() throws {
        let r = try XCTUnwrap(reference("../Lib/a.pdf#page=3&gid=\(id)&q=hello%20world"))
        XCTAssertEqual(r.path, "../Lib/a.pdf")
        XCTAssertEqual(r.page, 3)
        XCTAssertEqual(r.documentID, id)
        XCTAssertEqual(r.snippet, "hello world")
    }

    func testAPlainPageLinkIsNotACitation() {
        XCTAssertNil(reference("a.pdf#page=3"))
        XCTAssertNil(reference("a.pdf"))
    }

    func testInvalidLinksAreRefused() {
        XCTAssertNil(reference("a.pdf#page=0&gid=\(id)"), "page 0")
        XCTAssertNil(reference("a.pdf#page=-2&gid=\(id)"))
        XCTAssertNil(reference("a.pdf#page=x&gid=\(id)"))
        XCTAssertNil(reference("a.pdf#page=2&gid=XYZ"), "id not hex")
        XCTAssertNil(reference("a.pdf#page=2&gid=3FA9C1D2E4B50A77"), "id is lowercase")
        XCTAssertNil(reference("a.pdf#page=2&gid=3fa9"), "id too short")
    }

    func testAbsoluteFileLinksKeepTheirPath() throws {
        let r = try XCTUnwrap(reference("file:///Users/me/My%20Papers/a.pdf#page=1&gid=\(id)"))
        XCTAssertEqual(r.path, "/Users/me/My Papers/a.pdf")
    }

    func testTheNotePointsOutItsCitations() {
        let note = """
        # Reading
        > One.
        > — [Doc, p. 2](Papers/a.pdf#page=2&gid=\(id))

        See [site](https://example.com) and [plain](a.pdf#page=9) and [other](b.pdf#page=4&gid=0123456789abcdef).
        > — [Doc, p. 5](Papers/a.pdf#page=5&gid=\(id)&q=x)
        """
        let refs = PDFCitation.references(in: note)
        XCTAssertEqual(refs.count, 3)
        XCTAssertEqual(PDFCitingNotes.citedPages(in: note, of: id), [2, 5])
        XCTAssertEqual(PDFCitingNotes.citedPages(in: note, of: "0123456789abcdef"), [4])
        XCTAssertEqual(PDFCitingNotes.citedPages(in: "no links here", of: id), [])
    }

    func testRelativePaths() {
        let base = URL(fileURLWithPath: "/Users/me/Notes")
        XCTAssertEqual(PDFCitation.relativePath(from: base, to: URL(fileURLWithPath: "/Users/me/Notes/a.pdf")), "a.pdf")
        XCTAssertEqual(PDFCitation.relativePath(from: base, to: URL(fileURLWithPath: "/Users/me/Papers/a.pdf")), "../Papers/a.pdf")
        XCTAssertEqual(PDFCitation.relativePath(from: base, to: URL(fileURLWithPath: "/Volumes/X/a.pdf")), "file:///Volumes/X/a.pdf", "nothing in common but /")
        XCTAssertTrue(PDFCitation.linkPath(to: URL(fileURLWithPath: "/a/b.pdf"), from: nil).hasPrefix("file:///"), "an unsaved note writes a file URL")
    }
}

// MARK: Identity

final class PDFDocumentFingerprintTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = try tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testTheSameContentHasTheSameIdentityWhereverTheFileIs() throws {
        let a = makePDF(at: dir.appendingPathComponent("a.pdf"), pages: paper)
        let b = makePDF(at: dir.appendingPathComponent("renamed copy.pdf"), pages: paper)
        let idA = try XCTUnwrap(PDFDocumentFingerprint.of(fileAt: a))
        XCTAssertEqual(idA, PDFDocumentFingerprint.of(fileAt: b))
        XCTAssertTrue(PDFCitation.isValidID(idA), idA)
    }

    func testDifferentDocumentsWithTheSameNameAreTold() throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("y"), withIntermediateDirectories: true)
        let one = makePDF(at: dir.appendingPathComponent("x/paper.pdf"), pages: paper)
        let two = makePDF(at: dir.appendingPathComponent("y/paper.pdf"), pages: ["Another paper entirely.", "Different text"])
        XCTAssertNotEqual(PDFDocumentFingerprint.of(fileAt: one), PDFDocumentFingerprint.of(fileAt: two))
    }

    func testAPageCountOrSizeChangeIsADifferentDocument() throws {
        let base = try XCTUnwrap(PDFDocumentFingerprint.of(fileAt: makePDF(at: dir.appendingPathComponent("1.pdf"), pages: paper)))
        let more = PDFDocumentFingerprint.of(fileAt: makePDF(at: dir.appendingPathComponent("2.pdf"), pages: paper + ["third"]))
        let a5 = PDFDocumentFingerprint.of(fileAt: makePDF(at: dir.appendingPathComponent("3.pdf"), pages: paper, size: CGSize(width: 420, height: 595)))
        XCTAssertNotEqual(base, more)
        XCTAssertNotEqual(base, a5)
    }

    /// Glossa saves highlights into the file: that rewrites its bytes and must not change who it is.
    func testSavingAHighlightIntoTheFileKeepsItsIdentity() throws {
        let url = makePDF(at: dir.appendingPathComponent("hl.pdf"), pages: paper)
        let before = try XCTUnwrap(PDFDocumentFingerprint.of(fileAt: url))
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let highlight = PDFAnnotation(bounds: CGRect(x: 72, y: 695, width: 200, height: 18), forType: .highlight, withProperties: nil)
        page.addAnnotation(highlight)
        XCTAssertTrue(document.write(to: url))
        XCTAssertEqual(PDFDocumentFingerprint.of(fileAt: url), before)
    }

    func testAScanWithNoTextFallsBackToTheHeadOfTheFile() throws {
        let a = makePDF(at: dir.appendingPathComponent("scan1.pdf"), pages: ["", ""])
        let copy = dir.appendingPathComponent("scan-copy.pdf")
        try FileManager.default.copyItem(at: a, to: copy)
        XCTAssertNotNil(PDFDocumentFingerprint.of(fileAt: a))
        XCTAssertEqual(PDFDocumentFingerprint.of(fileAt: a), PDFDocumentFingerprint.of(fileAt: copy))
    }

    func testSpacingAndCaseOfExtractionDoNotMatter() {
        let one = PDFDocumentFingerprint.make(pageCount: 2, firstPageSize: CGSize(width: 612, height: 792), pageTexts: ["Hello   World\n"]) { nil }
        let two = PDFDocumentFingerprint.make(pageCount: 2, firstPageSize: CGSize(width: 612, height: 792), pageTexts: ["hello world"]) { nil }
        XCTAssertEqual(one, two)
    }

    func testNotAPDFHasNoIdentity() throws {
        let junk = dir.appendingPathComponent("junk.pdf")
        try Data("not a pdf".utf8).write(to: junk)
        XCTAssertNil(PDFDocumentFingerprint.of(fileAt: junk))
        XCTAssertNil(PDFDocumentFingerprint.of(fileAt: dir.appendingPathComponent("missing.pdf")))
    }
}

// MARK: Registry

final class PDFDocumentRegistryTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = try tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testARegisteredDocumentIsFoundWhereItIs() throws {
        let url = makePDF(at: dir.appendingPathComponent("a.pdf"), pages: paper)
        let r = registry()
        r.register(id: id, url: url, title: "Attention")
        XCTAssertEqual(r.record(for: id)?.title, "Attention")
        XCTAssertEqual(r.locate(id: id)?.url.resolvingSymlinksInPath(), url.resolvingSymlinksInPath())
    }

    /// The bookmark follows the file where the path no longer does.
    func testAMovedAndRenamedFileIsFoundThroughItsBookmark() throws {
        let url = makePDF(at: dir.appendingPathComponent("a.pdf"), pages: paper)
        let r = registry()
        r.register(id: id, url: url, title: "T")
        let moved = dir.appendingPathComponent("elsewhere/b renamed.pdf")
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: moved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(r.locate(id: id)?.url.resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
    }

    func testADeletedFileIsNotFoundAndAnUnknownIDIsNot() throws {
        let url = makePDF(at: dir.appendingPathComponent("a.pdf"), pages: paper)
        let r = registry()
        r.register(id: id, url: url, title: "T")
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(r.locate(id: id))
        XCTAssertNil(r.locate(id: "0123456789abcdef"))
    }

    func testTheRegistryIsKeptBetweenLaunches() throws {
        let suite = "pdfcitation.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = makePDF(at: dir.appendingPathComponent("a.pdf"), pages: paper)
        PDFDocumentRegistry(defaults: defaults, scoped: false).register(id: id, url: url, title: "Kept")
        let again = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(again.record(for: id)?.title, "Kept")
        XCTAssertNotNil(again.locate(id: id))
    }

    func testAnInvalidIDIsNotRegisteredAndTheRegistryIsBounded() throws {
        let url = makePDF(at: dir.appendingPathComponent("a.pdf"), pages: paper)
        let r = registry()
        r.register(id: "nope", url: url, title: "x")
        XCTAssertEqual(r.count, 0)
        for i in 0..<(PDFDocumentRegistry.capacity + 20) { r.register(id: String(format: "%016x", i), url: url, title: "d\(i)") }
        XCTAssertEqual(r.count, PDFDocumentRegistry.capacity)
    }

    func testNotesThatQuoteADocumentAreRememberedWithoutRepeats() throws {
        let pdf = makePDF(at: dir.appendingPathComponent("a.pdf"), pages: paper)
        let note = dir.appendingPathComponent("n.md")
        try "x".write(to: note, atomically: true, encoding: .utf8)
        let r = registry()
        r.register(id: id, url: pdf, title: "T")
        r.recordNote(note, citing: id)
        r.recordNote(note, citing: id)
        XCTAssertEqual(r.notes(citing: id).count, 1)
        r.recordNote(note, citing: "0123456789abcdef")
        XCTAssertTrue(r.notes(citing: "0123456789abcdef").isEmpty, "only for a registered document")
        try FileManager.default.removeItem(at: note)
        XCTAssertTrue(r.notes(citing: id).isEmpty)
    }
}

// MARK: Resolver

final class PDFCitationResolverTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = try tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func sub(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func reference(for url: URL, noteFolder: URL, page: Int = 2) throws -> PDFCitation.Reference {
        let documentID = try XCTUnwrap(PDFDocumentFingerprint.of(fileAt: url))
        let path = PDFCitation.linkPath(to: url, from: noteFolder)
        return try XCTUnwrap(PDFCitation.Reference(path: path, fragment: "page=\(page)&gid=\(documentID)"))
    }

    private func found(_ outcome: PDFCitationResolver.Outcome) -> URL? {
        if case .found(let file) = outcome { return file.url.resolvingSymlinksInPath() }
        return nil
    }

    func testTheFileAtTheLinkedPathIsFound() throws {
        let notes = try sub("notes"), lib = try sub("lib")
        let pdf = makePDF(at: lib.appendingPathComponent("paper.pdf"), pages: paper)
        let ref = try reference(for: pdf, noteFolder: notes)
        XCTAssertEqual(ref.path, "../lib/paper.pdf")
        XCTAssertEqual(found(PDFCitationResolver(registry: registry()).resolve(ref, noteFolder: notes)), pdf.resolvingSymlinksInPath())
    }

    func testAMovedFileIsFoundThroughTheRegistry() throws {
        let notes = try sub("notes"), lib = try sub("lib"), archive = try sub("archive")
        let pdf = makePDF(at: lib.appendingPathComponent("paper.pdf"), pages: paper)
        let ref = try reference(for: pdf, noteFolder: notes)
        let reg = registry()
        reg.register(id: ref.documentID, url: pdf, title: "T")
        let moved = archive.appendingPathComponent("Paper (final).pdf")
        try FileManager.default.moveItem(at: pdf, to: moved)
        XCTAssertEqual(found(PDFCitationResolver(registry: reg).resolve(ref, noteFolder: notes)), moved.resolvingSymlinksInPath())
    }

    func testAMovedFileNobodyRegisteredIsFoundByNameInTheNotesTree() throws {
        let notes = try sub("notes"), lib = try sub("lib")
        let pdf = makePDF(at: lib.appendingPathComponent("paper.pdf"), pages: paper)
        let ref = try reference(for: pdf, noteFolder: notes)
        let moved = try sub("notes/attachments").appendingPathComponent("paper.pdf")
        try FileManager.default.moveItem(at: pdf, to: moved)
        XCTAssertEqual(found(PDFCitationResolver(registry: registry()).resolve(ref, noteFolder: notes)), moved.resolvingSymlinksInPath())
    }

    /// Two PDFs share a name: the one cited is the one found, not the first.
    func testTwoDocumentsWithTheSameNameAreNotMixedUp() throws {
        let notes = try sub("notes"), one = try sub("notes/one"), two = try sub("notes/two")
        let first = makePDF(at: one.appendingPathComponent("paper.pdf"), pages: ["First document text.", "p2"])
        let second = makePDF(at: two.appendingPathComponent("paper.pdf"), pages: ["Second document text.", "p2"])
        let citesSecond = try reference(for: second, noteFolder: notes)
        let citesFirst = try reference(for: first, noteFolder: notes)
        let resolver = PDFCitationResolver(registry: registry())
        XCTAssertEqual(found(resolver.resolve(citesSecond, noteFolder: notes)), second.resolvingSymlinksInPath())
        XCTAssertEqual(found(resolver.resolve(citesFirst, noteFolder: notes)), first.resolvingSymlinksInPath())
        // Delete the one cited: the other, though it has the same name, is not offered in its place.
        try FileManager.default.removeItem(at: second)
        XCTAssertEqual(resolver.resolve(citesSecond, noteFolder: notes), .missing(name: "paper.pdf"))
    }

    func testADifferentFileAtTheOldPathIsNotMistakenForIt() throws {
        let notes = try sub("notes")
        let pdf = makePDF(at: notes.appendingPathComponent("paper.pdf"), pages: paper)
        let ref = try reference(for: pdf, noteFolder: notes)
        makePDF(at: pdf, pages: ["Replaced by something else.", "x"])
        XCTAssertEqual(PDFCitationResolver(registry: registry()).resolve(ref, noteFolder: notes), .missing(name: "paper.pdf"))
    }

    func testAMissingDocumentIsAnAnswerWithItsName() throws {
        let notes = try sub("notes")
        let pdf = makePDF(at: notes.appendingPathComponent("gone.pdf"), pages: paper)
        let ref = try reference(for: pdf, noteFolder: notes)
        try FileManager.default.removeItem(at: pdf)
        XCTAssertEqual(PDFCitationResolver(registry: registry()).resolve(ref, noteFolder: notes), .missing(name: "gone.pdf"))
    }

    func testAnUnsavedNoteWithARelativePathCannotResolveItButDoesNotCrash() throws {
        let ref = try XCTUnwrap(PDFCitation.Reference(path: "a.pdf", fragment: "page=1&gid=\(id)"))
        XCTAssertEqual(PDFCitationResolver(registry: registry()).resolve(ref, noteFolder: nil), .missing(name: "a.pdf"))
    }

    func testTheSearchIsBounded() throws {
        let notes = try sub("notes")
        for i in 0..<30 { try Data().write(to: notes.appendingPathComponent("f\(i).txt")) }
        var resolver = PDFCitationResolver(registry: registry())
        resolver.maxEntries = 10
        XCTAssertTrue(resolver.candidates(named: "f29.txt", in: [notes]).isEmpty, "the budget ran out before reaching it")
    }
}

// MARK: Reverse links

final class PDFCitingNotesTests: XCTestCase {
    private var dir: URL!
    override func setUpWithError() throws { dir = try tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func note(_ name: String, citing pages: [Int], id documentID: String = id) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let body = pages.map { "> q\n> — [D, p. \($0)](a.pdf#page=\($0)&gid=\(documentID))" }.joined(separator: "\n\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testNotesBesideThePDFAreFoundWithTheirPages() throws {
        _ = try note("one.md", citing: [3, 1, 3])
        _ = try note("two.md", citing: [7])
        _ = try note("other.md", citing: [2], id: "0123456789abcdef")
        try "plain".write(to: dir.appendingPathComponent("three.md"), atomically: true, encoding: .utf8)
        try "ignored".write(to: dir.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let found = PDFCitingNotes.find(id: id, pdfFolder: dir, openNotes: [], registry: registry())
        XCTAssertEqual(found.map(\.title), ["one", "two"], "most quotes first")
        XCTAssertEqual(found[0].pages, [1, 3])
        XCTAssertEqual(found[0].count, 3)
    }

    func testAnOpenNoteCountsWithItsLiveTextAndIsNotListedTwice() throws {
        let saved = try note("one.md", citing: [3])
        let live = "now cites [x](a.pdf#page=9&gid=\(id)) and [y](a.pdf#page=10&gid=\(id))"
        let found = PDFCitingNotes.find(id: id, pdfFolder: dir, openNotes: [.init(url: saved, text: live)], registry: registry())
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].pages, [9, 10], "the unsaved text wins over the file")
    }

    func testAnUnsavedNoteHasNoFileToListButTheFolderScanStillWorks() throws {
        let found = PDFCitingNotes.find(id: id, pdfFolder: nil, openNotes: [.init(url: nil, text: "[x](a.pdf#page=1&gid=\(id))")], registry: registry())
        XCTAssertTrue(found.isEmpty)
    }

    func testANoteElsewhereThatRememberedQuotingIsFound() throws {
        let pdfDir = dir.appendingPathComponent("pdfs"), notesDir = dir.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: pdfDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notesDir, withIntermediateDirectories: true)
        let pdf = makePDF(at: pdfDir.appendingPathComponent("a.pdf"), pages: paper)
        let text = notesDir.appendingPathComponent("remembered.md")
        try "[x](../pdfs/a.pdf#page=4&gid=\(id))".write(to: text, atomically: true, encoding: .utf8)
        let reg = registry()
        reg.register(id: id, url: pdf, title: "T")
        reg.recordNote(text, citing: id)
        let found = PDFCitingNotes.find(id: id, pdfFolder: pdfDir, openNotes: [], registry: reg)
        XCTAssertEqual(found.map(\.title), ["remembered"])
        XCTAssertEqual(found.first?.pages, [4])
    }
}

// MARK: The block inserted into a note (the engine's side is tested with its own package)

final class PDFCitationBlockTests: XCTestCase {
    func testAQuoteInsertedMidTextGetsABlankLineOnEachSide() throws {
        let c = PDFCitation(title: "D", page: 1, path: "a.pdf", documentID: id, quote: "Q")
        let block = c.markdown().trimmingCharacters(in: .newlines)
        XCTAssertTrue(block.hasPrefix("> Q\n>\n> — [D, p. 1]"))
        XCTAssertFalse(block.hasSuffix("\n"))
    }
}
