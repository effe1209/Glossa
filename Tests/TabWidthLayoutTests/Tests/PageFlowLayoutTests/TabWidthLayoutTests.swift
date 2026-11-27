import XCTest
@testable import PageFlowLayout

final class TabWidthLayoutTests: XCTestCase {
    private func layout(_ count: Int, _ available: CGFloat) -> TabWidthLayout {
        TabWidthLayout(count: count, availableWidth: available, spacing: 2, preferredWidth: 200, minWidth: 100, maxWidth: 240)
    }

    func testFewTabsStayAtPreferredWidth() {
        XCTAssertEqual(layout(1, 1000).tabWidth, 200)
        XCTAssertEqual(layout(3, 1000).tabWidth, 200)
        XCTAssertFalse(layout(3, 1000).scrolls)
    }

    func testTabsShrinkToFillAvailableWidth() {
        let l = layout(8, 1000) // (1000 - 14) / 8 = 123.25
        XCTAssertEqual(l.tabWidth, 123)
        XCTAssertLessThanOrEqual(8 * l.tabWidth + 14, 1000)
        XCTAssertFalse(l.scrolls)
    }

    func testWidthNeverDropsBelowMinimumAndScrolls() {
        let l = layout(30, 1000)
        XCTAssertEqual(l.tabWidth, 100)
        XCTAssertTrue(l.scrolls)
    }

    func testExactMinimumFitDoesNotScroll() {
        XCTAssertFalse(layout(3, 3 * 100 + 4).scrolls)
        XCTAssertTrue(layout(3, 3 * 100 + 3).scrolls)
    }

    func testTabsExpandBackWhenSpaceReturns() {
        XCTAssertGreaterThan(layout(8, 1400).tabWidth, layout(8, 1000).tabWidth)
        XCTAssertGreaterThan(layout(5, 1000).tabWidth, layout(8, 1000).tabWidth)
    }

    func testPreferredIsCappedByMaximum() {
        let l = TabWidthLayout(count: 1, availableWidth: 1000, spacing: 2, preferredWidth: 300, minWidth: 100, maxWidth: 240)
        XCTAssertEqual(l.tabWidth, 240)
    }

    func testUnmeasuredOrEmptyFallsBackToPreferred() {
        XCTAssertEqual(layout(5, 0).tabWidth, 200)
        XCTAssertEqual(layout(0, 500).tabWidth, 200)
        XCTAssertFalse(layout(5, 0).scrolls)
    }

    func testNarrowWindowClampsToMinimum() {
        XCTAssertEqual(layout(2, 50).tabWidth, 100)
        XCTAssertTrue(layout(2, 50).scrolls)
    }

    func testDeterministic() {
        XCTAssertEqual(layout(7, 913), layout(7, 913))
    }

    func testMinimumContentWidth() {
        XCTAssertEqual(TabWidthLayout.minimumContentWidth(count: 0, spacing: 2, minWidth: 100), 0)
        XCTAssertEqual(TabWidthLayout.minimumContentWidth(count: 3, spacing: 2, minWidth: 100), 304)
    }
}
