import PDFKit
import XCTest
@testable import PDFZoomFit

final class PDFZoomFitTests: XCTestCase {
    private let a4 = CGSize(width: 595, height: 842)
    private let slide = CGSize(width: 960, height: 540)

    private func layout(_ width: CGFloat, _ height: CGFloat, _ mode: PDFDisplayMode = .singlePageContinuous) -> PDFZoomFit.Layout {
        PDFZoomFit.Layout(viewportSize: CGSize(width: width, height: height), displayMode: mode, padding: 20, twoPageGap: 10)
    }

    // MARK: Effective size

    func testRotationByAQuarterTurnSwapsWidthAndHeight() {
        XCTAssertEqual(PDFZoomFit.effectiveSize(boxSize: a4, rotation: 0), a4)
        XCTAssertEqual(PDFZoomFit.effectiveSize(boxSize: a4, rotation: 180), a4)
        XCTAssertEqual(PDFZoomFit.effectiveSize(boxSize: a4, rotation: 90), CGSize(width: 842, height: 595))
        XCTAssertEqual(PDFZoomFit.effectiveSize(boxSize: a4, rotation: 270), CGSize(width: 842, height: 595))
        XCTAssertEqual(PDFZoomFit.effectiveSize(boxSize: a4, rotation: -90), CGSize(width: 842, height: 595))
    }

    // MARK: Fit Width

    func testFitWidthUsesOnlyTheWidth() throws {
        let tall = try XCTUnwrap(PDFZoomFit.scale(mode: .width, pageSize: a4, layout: layout(1020, 300)))
        XCTAssertEqual(tall, (1020 - 20) / 595, accuracy: 1e-9)       // a short window doesn't matter
        let tallWindow = try XCTUnwrap(PDFZoomFit.scale(mode: .width, pageSize: a4, layout: layout(1020, 5000)))
        XCTAssertEqual(tallWindow, tall, accuracy: 1e-9)
    }

    func testFitWidthOfASpreadFitsBothPagesAndTheGap() throws {
        let scale = try XCTUnwrap(PDFZoomFit.scale(mode: .width, pageSize: a4, layout: layout(1220, 900, .twoUpContinuous)))
        XCTAssertEqual(scale, (1220 - 20) / (595 * 2 + 10), accuracy: 1e-9)
    }

    // MARK: Fit Page

    func testFitPageTakesTheTighterDimension() throws {
        // A4 in a wide, short window: height decides.
        let wide = try XCTUnwrap(PDFZoomFit.scale(mode: .page, pageSize: a4, layout: layout(1600, 900)))
        XCTAssertEqual(wide, (900 - 20) / 842, accuracy: 1e-9)
        // The same page in a narrow, tall window: width decides.
        let narrow = try XCTUnwrap(PDFZoomFit.scale(mode: .page, pageSize: a4, layout: layout(520, 1400)))
        XCTAssertEqual(narrow, (520 - 20) / 595, accuracy: 1e-9)
    }

    func testFitPageNeverOverflowsTheWindow() throws {
        for size in [a4, slide, CGSize(width: 300, height: 900), CGSize(width: 1200, height: 200)] {
            for (w, h) in [(1280.0, 800.0), (700.0, 1000.0), (400.0, 400.0)] {
                let scale = try XCTUnwrap(PDFZoomFit.scale(mode: .page, pageSize: size, layout: layout(w, h)))
                XCTAssertLessThanOrEqual(size.width * scale, w - 20 + 1e-9, "\(size) in \(w)x\(h)")
                XCTAssertLessThanOrEqual(size.height * scale, h - 20 + 1e-9, "\(size) in \(w)x\(h)")
            }
        }
    }

    // MARK: Mixed page formats

    func testASlideAndAnA4PageFitByTheirOwnShapes() throws {
        let window = layout(1300, 800)
        let a4Scale = try XCTUnwrap(PDFZoomFit.scale(mode: .page, pageSize: a4, layout: window))
        let slideScale = try XCTUnwrap(PDFZoomFit.scale(mode: .page, pageSize: slide, layout: window))
        XCTAssertEqual(a4Scale, (800 - 20) / 842, accuracy: 1e-9)       // portrait: height decides
        XCTAssertEqual(slideScale, (1300 - 20) / 960, accuracy: 1e-9)   // landscape: width decides
        XCTAssertNotEqual(a4Scale, slideScale, accuracy: 0.01)
    }

    func testARotatedPageFitsAsItsRotatedShape() throws {
        let turned = PDFZoomFit.effectiveSize(boxSize: a4, rotation: 90)
        let scale = try XCTUnwrap(PDFZoomFit.scale(mode: .page, pageSize: turned, layout: layout(1300, 800)))
        XCTAssertEqual(scale, min((1300 - 20) / 842, (800 - 20) / 595), accuracy: 1e-9)
    }

    // MARK: Following the window

    func testTheScaleFollowsTheWindowAndReturnsToTheSameValue() throws {
        let before = try XCTUnwrap(PDFZoomFit.scale(mode: .width, pageSize: a4, layout: layout(1000, 800)))
        let wider = try XCTUnwrap(PDFZoomFit.scale(mode: .width, pageSize: a4, layout: layout(1400, 800)))
        let after = try XCTUnwrap(PDFZoomFit.scale(mode: .width, pageSize: a4, layout: layout(1000, 800)))
        XCTAssertGreaterThan(wider, before)
        XCTAssertEqual(before, after, accuracy: 1e-12)
    }

    // MARK: Invalid geometry, limits

    func testUnusableGeometryGivesNoScale() {
        XCTAssertNil(PDFZoomFit.scale(mode: .page, pageSize: a4, layout: layout(0, 0)))
        XCTAssertNil(PDFZoomFit.scale(mode: .page, pageSize: a4, layout: layout(20, 800)))   // all padding
        XCTAssertNil(PDFZoomFit.scale(mode: .width, pageSize: .zero, layout: layout(1000, 800)))
        XCTAssertNil(PDFZoomFit.scale(mode: .width, pageSize: CGSize(width: 595, height: 0), layout: layout(1000, 800)))
    }

    func testClampingKeepsAScaleInTheZoomRange() {
        XCTAssertEqual(PDFZoomFit.clamped(9, minimum: 0.1, maximum: 4), 4)
        XCTAssertEqual(PDFZoomFit.clamped(0.01, minimum: 0.1, maximum: 4), 0.1)
        XCTAssertEqual(PDFZoomFit.clamped(1.5, minimum: 0.1, maximum: 4), 1.5)
    }

    func testTheDisplayModeImpliesAFit() {
        XCTAssertEqual(PDFZoomFit.Mode.implied(by: .singlePageContinuous), .width)
        XCTAssertEqual(PDFZoomFit.Mode.implied(by: .twoUpContinuous), .width)
        XCTAssertEqual(PDFZoomFit.Mode.implied(by: .singlePage), .page)
        XCTAssertEqual(PDFZoomFit.Mode.implied(by: .twoUp), .page)
    }

    func testPercentageRoundsToWholeNumbers() {
        XCTAssertEqual(PDFZoomFit.percentage(of: 1), 100)
        XCTAssertEqual(PDFZoomFit.percentage(of: 1.2549), 125)
        XCTAssertEqual(PDFZoomFit.percentage(of: 0.1), 10)
        XCTAssertEqual(PDFZoomFit.percentage(of: 0), 0)
        XCTAssertEqual(PDFZoomFit.percentage(of: .nan), 0)
    }

    // MARK: Real PDFKit pages

    /// The sizes this reads come from PDFKit pages with different boxes and rotations,
    /// as the live view reads them, so the formula is checked on real input.
    func testRealPagesOfDifferentFormatsAndRotations() throws {
        let document = PDFDocument()
        let a4Page = try XCTUnwrap(blankPage(size: a4))
        let slidePage = try XCTUnwrap(blankPage(size: slide))
        document.insert(a4Page, at: 0)
        document.insert(slidePage, at: 1)
        let window = layout(1300, 800)

        func fit(_ page: PDFPage) throws -> CGFloat {
            let size = PDFZoomFit.effectiveSize(boxSize: page.bounds(for: .cropBox).size, rotation: page.rotation)
            return try XCTUnwrap(PDFZoomFit.scale(mode: .page, pageSize: size, layout: window))
        }
        let portrait = try fit(a4Page)
        slidePage.rotation = 90                                  // a landscape slide turned upright
        let turned = try fit(slidePage)
        XCTAssertEqual(turned, (800 - 20) / 960, accuracy: 1e-9)  // now 540 wide, 960 tall: height decides
        XCTAssertNotEqual(portrait, turned, accuracy: 0.01)
    }

    private func blankPage(size: CGSize) -> PDFPage? {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0).flatMap { $0.copy() as? PDFPage }
    }
}

final class RailPageGeometryTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 40, width: 1200, height: 800)

    private func page(x: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    func testPagesStackedInAColumnAreOneColumnSpanningTheViewport() {
        let pages = [page(x: 300, width: 600, y: 40, height: 300), page(x: 300, width: 600, y: 350, height: 450)]
        let columns = RailPageGeometry.columns(of: pages, in: viewport)
        XCTAssertEqual(columns, [CGRect(x: 300, y: 40, width: 600, height: 800)])
    }

    /// The point of it: scrolling moves the pages up and down and changes nothing
    /// the rail is told, so nothing is published while the reader scrolls.
    func testScrollingDoesNotChangeTheColumns() {
        let first = RailPageGeometry.columns(of: [page(x: 300, width: 600, y: 40, height: 500),
                                                  page(x: 300, width: 600, y: 550, height: 290)], in: viewport)
        for offset in stride(from: 0.0, through: 900.0, by: 37.0) {
            let moved = RailPageGeometry.columns(of: [page(x: 300, width: 600, y: 40, height: 400 + offset.truncatingRemainder(dividingBy: 200)),
                                                      page(x: 300, width: 600, y: 450, height: 390)], in: viewport)
            XCTAssertTrue(RailPageGeometry.sameLayout(first, moved), "offset \(offset)")
        }
    }

    func testPagesOfASpreadAreTwoColumns() {
        let pages = [page(x: 100, width: 500, y: 40, height: 800), page(x: 620, width: 500, y: 40, height: 800)]
        XCTAssertEqual(RailPageGeometry.columns(of: pages, in: viewport).count, 2)
    }

    func testPagesOfDifferentWidthsStackedMergeToTheirUnion() {
        let pages = [page(x: 300, width: 600, y: 40, height: 300), page(x: 120, width: 960, y: 350, height: 450)]
        XCTAssertEqual(RailPageGeometry.columns(of: pages, in: viewport), [CGRect(x: 120, y: 40, width: 960, height: 800)])
    }

    func testAZoomIsALayoutChange() {
        let before = RailPageGeometry.columns(of: [page(x: 300, width: 600, y: 40, height: 800)], in: viewport)
        let after = RailPageGeometry.columns(of: [page(x: 200, width: 800, y: 40, height: 800)], in: viewport)
        XCTAssertFalse(RailPageGeometry.sameLayout(before, after))
    }

    func testSubPointJitterIsNotALayoutChange() {
        let a = [CGRect(x: 300, y: 40, width: 600, height: 800)]
        let b = [CGRect(x: 300.3, y: 40, width: 599.8, height: 800)]
        XCTAssertTrue(RailPageGeometry.sameLayout(a, b))
    }

    func testNothingVisibleIsNoColumns() {
        XCTAssertEqual(RailPageGeometry.columns(of: [], in: viewport), [])
        XCTAssertEqual(RailPageGeometry.columns(of: [page(x: 0, width: 10, y: 0, height: 10)], in: .zero), [])
        XCTAssertTrue(RailPageGeometry.sameLayout([], []))
    }
}
