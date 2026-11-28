import XCTest
import SwiftUI
import AppKit
@testable import LegacyMigration

// The "Allow Files and Folders" window must give its rows room. The list is measured in a real window made the
// way the app makes it (NSWindow(contentViewController: NSHostingController)), kept off screen. No app is started,
// and nothing of the reader's is read.

@MainActor final class AuthorizationLayoutTests: XCTestCase {
    private struct Measure {
        var windowContent: CGFloat
        var scrollViews: [NSScrollView]
        var listHeight: CGFloat { scrollViews.first?.frame.height ?? 0 }
        var documentHeight: CGFloat { scrollViews.first?.documentView?.frame.height ?? 0 }
    }

    private func items(_ n: Int, folders: Bool = true) -> [PendingAuthorization] {
        (0..<n).map { i in
            PendingAuthorization(.init(store: folders && i % 2 == 0 ? "folderAccessBookmarks.v1" : "recentFiles",
                                       subject: "/Users/glossatest/Documents/GlossaTestFiles/Item \(i)",
                                       outcome: .unresolvable, action: .dropped))
        }
    }

    private func collect(_ view: NSView, into found: inout [NSScrollView]) {
        if let scroll = view as? NSScrollView { found.append(scroll) }
        for sub in view.subviews { collect(sub, into: &found) }
    }

    private func measure(_ list: [PendingAuthorization], message: String? = nil) throws -> Measure {
        guard !NSScreen.screens.isEmpty else { throw XCTSkip("no window server") }
        _ = NSApplication.shared
        let content = AuthorizationContent(items: list, message: message, allow: { _ in }, close: {})
        let panel = NSWindow(contentViewController: NSHostingController(rootView: content))
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.setFrameOrigin(NSPoint(x: -6000, y: -6000))      // off screen
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        var scrolls: [NSScrollView] = []
        collect(try XCTUnwrap(panel.contentView), into: &scrolls)
        return Measure(windowContent: panel.contentView!.bounds.height, scrollViews: scrolls)
    }

    func testAnEmptyListShowsNoListAndKeepsTheWindowSmall() throws {
        let empty = try measure([])
        XCTAssertTrue(empty.scrollViews.isEmpty, "'Nothing left to allow.' has no scroll view")
        XCTAssertGreaterThan(empty.windowContent, 100)
        XCTAssertLessThan(empty.windowContent, 260)
    }

    func testOneTwoAndFewRowsGetTheHeightOfTheirRows() throws {
        let empty = try measure([]).windowContent
        var last: CGFloat = 0
        for n in [1, 2, 3, 5] {
            let m = try measure(items(n))
            XCTAssertEqual(m.scrollViews.count, 1, "\(n) item(s)")
            XCTAssertGreaterThan(m.listHeight, CGFloat(n) * 30, "\(n) item(s): the rows are given room, not collapsed to nothing")
            XCTAssertLessThan(m.listHeight, AuthorizationContent.listMaxHeight, "\(n) item(s): under the cap")
            XCTAssertEqual(m.documentHeight, m.listHeight, accuracy: 2, "\(n) item(s): everything fits, nothing to scroll")
            XCTAssertGreaterThan(m.windowContent, empty, "the window grows with the rows")
            XCTAssertGreaterThan(m.listHeight, last, "more rows, more height")
            last = m.listHeight
        }
    }

    func testManyRowsAreCappedAndScroll() throws {
        let cap = AuthorizationContent.listMaxHeight
        for n in [8, 12, 40] {
            let m = try measure(items(n))
            XCTAssertEqual(m.scrollViews.count, 1)
            XCTAssertEqual(m.listHeight, cap, accuracy: 0.5, "\(n) items: the list stops at the cap")
            XCTAssertGreaterThan(m.documentHeight, cap, "\(n) items: the rest is reached by scrolling")
        }
        let few = try measure(items(12)).windowContent
        let lots = try measure(items(40)).windowContent
        XCTAssertEqual(few, lots, accuracy: 0.5, "the window stops growing with the list")
    }

    func testTheListNeverSpillsOverTheButton() throws {
        // With the cap applied after the height of the rows, the rows would overflow the window: the list's
        // frame has to be inside it, whatever the number of rows.
        for n in [1, 2, 12, 40] {
            let m = try measure(items(n))
            XCTAssertLessThanOrEqual(m.listHeight, AuthorizationContent.listMaxHeight + 0.5)
            XCTAssertLessThan(m.listHeight, m.windowContent, "\(n) items")
        }
    }

    func testAMessageAddsRoomWithoutHidingTheRows() throws {
        let plain = try measure(items(2))
        let withMessage = try measure(items(2), message: "That is not Item 0. Choose Item 0 to allow it.")
        XCTAssertGreaterThan(withMessage.windowContent, plain.windowContent)
        XCTAssertEqual(withMessage.listHeight, plain.listHeight, accuracy: 0.5)
    }

    func testTheStructureThatMakesItWork() throws {
        let url = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { u, _ in u.deletingLastPathComponent() }
            .appendingPathComponent("PageFlow/Views/AuthorizationContent.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        let cap = try XCTUnwrap(code.range(of: ".frame(maxHeight: Self.listMaxHeight)"))
        let fixed = try XCTUnwrap(code.range(of: ".fixedSize(horizontal: false, vertical: true)    // …then"))
        XCTAssertLessThan(cap.lowerBound, fixed.lowerBound, "the cap goes before fixedSize: the other order lets the rows spill over")
        XCTAssertEqual(AuthorizationContent.listMaxHeight, 260)
        let view = try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("MigrationView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("AuthorizationContent(items: model.items"))
        XCTAssertFalse(view.contains(".frame(maxHeight: 260)"), "the window uses the one layout, which is measured here")
    }
}
