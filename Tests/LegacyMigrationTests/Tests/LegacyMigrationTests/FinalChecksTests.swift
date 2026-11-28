import XCTest
import Observation
@testable import LegacyMigration

// The last checks on the PR 4 flow: the restart after an import, the refusal across launches, a
// folder authorized through a containing one, and the menu following the list. Temporary folders,
// suites named by a path inside one, in-memory destinations; no panel, no real preferences.

// MARK: - Helpers

private final class Mem: MigrationDestination {
    var store: [String: Any] = [:]
    var sets = 0
    func value(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any, forKey key: String) throws { sets += 1; store[key] = value }
    func remove(forKey key: String) throws { store[key] = nil }
}

private final class Reads: LegacyPreferencesSource {
    let values: [String: Any]
    var count = 0
    init(_ values: [String: Any] = ["settings.showTooltips": true, "settings.toolbarScale": 1.5]) { self.values = values }
    func snapshot() throws -> [String: Any] { count += 1; return values }
}

private func root() -> URL { (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() } }
private func source(_ name: String) throws -> String { try String(contentsOf: root().appendingPathComponent(name), encoding: .utf8) }

private func temp(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-final-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

/// Each call is a new "launch" of the same preferences file.
private func launcher(_ test: XCTestCase) throws -> () -> UserDefaults {
    let name = try temp(test).appendingPathComponent("glossa").path
    return { UserDefaults(suiteName: name)! }
}

private func coordinator(_ source: LegacyPreferencesSource, _ destination: MigrationDestination) -> LegacyMigrationCoordinator {
    LegacyMigrationCoordinator(source: source, destination: destination, isGlossa: true, isSandboxed: false)
}

private func folderItem(_ path: String) -> PendingAuthorization {
    PendingAuthorization(BookmarkFinding(store: "folderAccessBookmarks.v1", subject: path, outcome: .unresolvable, action: .dropped))
}

// MARK: - 1. The restart after an import

final class RestartAfterImportTests: XCTestCase {
    func testACompletedImportIsNotRepeatedAfterTheRestart() throws {
        let launch = try launcher(self)
        let data = Reads()
        guard case .imported = coordinator(data, UserDefaultsDestination(defaults: launch())).choose(.importNow) else { return XCTFail() }

        // The restarted app: new objects over the same preferences file.
        let after = UserDefaultsDestination(defaults: launch())
        let fresh = Reads()
        XCTAssertEqual(coordinator(fresh, after).evaluate(), .notNeeded(.alreadyMigrated))
        XCTAssertEqual(fresh.count, 0, "PageFlow's data is not even read again")
        guard case .imported(let report) = coordinator(fresh, after).choose(.importNow) else { return XCTFail() }
        XCTAssertEqual(report.state, .alreadyMigrated)
    }

    func testTheRestartHappensOnlyOnceTheMarkerAndEveryKeyAreReadBack() {
        let store = Mem()
        XCTAssertFalse(LegacyMigrationCoordinator.importIsRecorded(in: store), "nothing recorded")
        guard case .imported = coordinator(Reads(), store).choose(.importNow) else { return XCTFail() }
        XCTAssertTrue(LegacyMigrationCoordinator.importIsRecorded(in: store))

        // A key the marker says was written but that is not there: no restart.
        let missingKey = Mem()
        missingKey.store = store.store
        missingKey.store["settings.toolbarScale"] = nil
        XCTAssertFalse(LegacyMigrationCoordinator.importIsRecorded(in: missingKey))
        // Data without the marker: no restart.
        let noMarker = Mem()
        noMarker.store = store.store
        noMarker.store[MigrationMarker.key] = nil
        XCTAssertFalse(LegacyMigrationCoordinator.importIsRecorded(in: noMarker))
        // A marker that is not a marker.
        let garbage = Mem()
        garbage.store[MigrationMarker.key] = Data("x".utf8)
        XCTAssertFalse(LegacyMigrationCoordinator.importIsRecorded(in: garbage))
    }

    func testTheImportReturnsOnlyAfterEveryWriteSoARestartCannotComeBeforeThem() {
        let store = Mem()
        let outcome = coordinator(Reads(), store).choose(.importNow)
        guard case .imported(let report) = outcome else { return XCTFail() }
        XCTAssertEqual(Set(report.written).subtracting(store.store.keys), [], "everything reported written is in the store when the call returns")
        XCTAssertEqual(store.sets, report.written.count + 1, "the keys, then the marker")
    }

    func testTheRestartedAppsOwnStoresDoNotWriteOverTheImportedValues() throws {
        let launch = try launcher(self)
        // An import that brings a PDF registry and a list of permissions to allow again.
        let record = PDFDocumentRecord(id: "0123456789abcdef", title: "Imported", lastPath: "/imported.pdf", bookmark: nil,
                                       updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let registry = try JSONEncoder().encode(["0123456789abcdef": record])
        let values: [String: Any] = [PDFDocumentRegistry.legacyStorageKey: registry, "settings.showTooltips": true,
                                     "folderAccessBookmarks.v1": ["/a": Data("x".utf8)]]
        let first = UserDefaultsDestination(defaults: launch())
        guard case .imported = coordinator(DictionarySource(values: values), first).choose(.importNow) else { return XCTFail() }
        let before = ["settings.showTooltips", PDFDocumentRegistry.storageKey, PendingAuthorizationList.key, MigrationMarker.key]
            .map { launch().object(forKey: $0) as AnyObject }

        // The restart: the stores of this module load, which is all a start does to them.
        let defaults = launch()
        let loaded = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(loaded.record(for: "0123456789abcdef")?.title, "Imported")
        XCTAssertNil(loaded.issue)
        let state = PendingAuthorizationsState(destination: UserDefaultsDestination(defaults: defaults))
        XCTAssertEqual(state.items.map(\.path), ["/a"])
        _ = coordinator(Reads(), UserDefaultsDestination(defaults: defaults)).evaluate()

        let after = ["settings.showTooltips", PDFDocumentRegistry.storageKey, PendingAuthorizationList.key, MigrationMarker.key]
            .map { launch().object(forKey: $0) as AnyObject }
        for (old, new) in zip(before, after) { XCTAssertTrue(old.isEqual(new), "a value changed during the start") }
    }

    func testLoadingWritesNothingToTheDestination() {
        let store = Mem()
        store.store[PendingAuthorizationList.key] = try! PendingAuthorizationList.encode([folderItem("/a")])
        _ = PendingAuthorizationsState(destination: store)
        _ = coordinator(Reads(), store).evaluate()
        XCTAssertEqual(store.sets, 0)
    }

    func testTheOfferComesBeforeTheSessionIsRestoredAndTheRestartIsConfirmed() throws {
        let delegate = try source("Glossa/AppDelegate.swift")
        let offer = try XCTUnwrap(delegate.range(of: "MigrationPresenter.presentIfNeeded(recentFiles: recentFilesManager)"))
        let restore = try XCTUnwrap(delegate.range(of: "        restorePreviousSessionIfNeeded()\n"))
        XCTAssertLessThan(offer.lowerBound, restore.lowerBound, "no document is restored while the window is up")
        XCTAssertTrue(delegate.contains("{ return }"), "a restarting launch goes no further")

        let presenter = try source("Glossa/Migration/MigrationPresenter.swift")
        let check = try XCTUnwrap(presenter.range(of: "importIsRecorded(in: readback)"))
        let open = try XCTUnwrap(presenter.range(of: "NSWorkspace.shared.openApplication"))
        XCTAssertLessThan(check.lowerBound, open.lowerBound, "no new copy before the import is read back")
        XCTAssertTrue(presenter.contains("CFPreferencesAppSynchronize"))
    }

    func testTheMenuNeverImportsBecauseARunningAppWouldWriteItsOldCopiesBack() throws {
        let presenter = try source("Glossa/Migration/MigrationPresenter.swift")
        let start = try XCTUnwrap(presenter.range(of: "static func importFromMenu()"))
        let end = try XCTUnwrap(presenter.range(of: "private static func restart", range: start.upperBound..<presenter.endIndex))
        XCTAssertFalse(presenter[start.lowerBound..<end.lowerBound].contains("choose("))
        XCTAssertFalse(presenter[start.lowerBound..<end.lowerBound].contains("runOffer"))
    }
}

// MARK: - 2. "Don't import ever" across launches

final class RefusalAcrossLaunchesTests: XCTestCase {
    func testTheRefusalHoldsAcrossManyLaunchesAndPageFlowIsNeverReadAgain() throws {
        let launch = try launcher(self)
        let data = Reads()
        XCTAssertEqual(coordinator(data, UserDefaultsDestination(defaults: launch())).choose(.neverImport), .declinedForGood)

        for _ in 0..<4 {
            let reads = Reads(["settings.showTooltips": false, "settings.toolbarScale": 9.0])
            let destination = UserDefaultsDestination(defaults: launch())
            XCTAssertEqual(coordinator(reads, destination).evaluate(), .notNeeded(.declined))
            XCTAssertEqual(reads.count, 0, "after a refusal PageFlow's preferences are not read")
        }
        XCTAssertEqual(data.count, 0, "and the refusal itself read nothing")
        XCTAssertNil(launch().object(forKey: "settings.showTooltips"), "nothing was imported")
    }

    func testTheRefusalIsNotTheMarkerAndTheMarkerIsNotTheRefusal() throws {
        let launch = try launcher(self)
        _ = coordinator(Reads(), UserDefaultsDestination(defaults: launch())).choose(.neverImport)
        XCTAssertNotNil(launch().data(forKey: MigrationDeclined.key))
        XCTAssertNil(launch().object(forKey: MigrationMarker.key))
        XCTAssertNotEqual(MigrationDeclined.key, MigrationMarker.key)

        let other = try launcher(self)
        _ = coordinator(Reads(), UserDefaultsDestination(defaults: other())).choose(.importNow)
        XCTAssertNotNil(other().data(forKey: MigrationMarker.key))
        XCTAssertNil(other().object(forKey: MigrationDeclined.key))
    }

    func testTheRefusalWritesOnlyItsOwnKeyAndTheMenuReadsNothingAfterIt() throws {
        let store = Mem()
        let data = Reads()
        _ = coordinator(data, store).choose(.neverImport)
        XCTAssertEqual(Set(store.store.keys), [MigrationDeclined.key])
        // What the menu does: evaluate, which stops at the refusal.
        XCTAssertEqual(coordinator(data, store).evaluate(), .notNeeded(.declined))
        XCTAssertEqual(data.count, 0)
        XCTAssertEqual(store.sets, 1)
    }
}

// MARK: - 3. A containing folder

final class ContainingFolderTests: XCTestCase {
    private struct Setup {
        let defaults: UserDefaults
        let store: FolderAccessStore
        let service: PendingAuthorizationService
        let asked: Asked
    }
    private final class Asked { var paths: [String] = []; var answer: URL? }

    private func setup(destination: MigrationDestination) throws -> Setup {
        let launch = try launcher(self)
        let defaults = launch()
        let store = FolderAccessStore(defaults: defaults)
        let asked = Asked()
        let service = PendingAuthorizationService(
            destination: destination,
            isAlreadyAuthorized: { store.hasWorkingAccess(to: URL(fileURLWithPath: $0.path)) },
            pick: { item in asked.paths.append(item.path); return asked.answer.map { .chosen($0) } ?? .cancelled },
            grant: { item, chosen in store.allow(chosen, covering: URL(fileURLWithPath: item.path)) },
            verify: { item, _ in store.hasWorkingAccess(to: URL(fileURLWithPath: item.path)) })
        return Setup(defaults: defaults, store: store, service: service, asked: asked)
    }

    func testAllowingAFolderThatContainsTheRequestedOneGivesAWorkingBookmark() throws {
        let base = try temp(self)
        let parent = base.appendingPathComponent("Notes", isDirectory: true)
        let child = parent.appendingPathComponent("Sub/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let destination = Mem()
        try destination.set(try PendingAuthorizationList.encode([folderItem(child.path)]), forKey: PendingAuthorizationList.key)
        let s = try setup(destination: destination)
        s.asked.answer = parent

        XCTAssertEqual(s.service.attempt(s.service.list()[0]), .granted)
        XCTAssertTrue(s.service.list().isEmpty, "the entry left the list after the verification")

        // The stored bookmark is the containing folder's, and it really resolves.
        let stored = try XCTUnwrap(s.defaults.dictionary(forKey: "folderAccessBookmarks.v1") as? [String: Data])
        let data = try XCTUnwrap(stored[parent.standardizedFileURL.path])
        guard case .valid(let url) = LegacyBookmarkInspector(scoped: true).inspect(data) else { return XCTFail("the bookmark does not work") }
        XCTAssertEqual(url.resolvingSymlinksInPath().path, parent.resolvingSymlinksInPath().path)
        XCTAssertTrue(s.store.hasWorkingAccess(to: child), "the access covers the folder that was asked for")
    }

    func testAnotherRequestUnderTheSameFolderIsNotAskedAgain() throws {
        let base = try temp(self)
        let parent = base.appendingPathComponent("Notes", isDirectory: true)
        let first = parent.appendingPathComponent("One", isDirectory: true)
        let second = parent.appendingPathComponent("Two/Inner", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let destination = Mem()
        try destination.set(try PendingAuthorizationList.encode([folderItem(first.path), folderItem(second.path)]), forKey: PendingAuthorizationList.key)
        let s = try setup(destination: destination)
        s.asked.answer = parent
        XCTAssertEqual(s.service.attempt(s.service.list()[0]), .granted)
        XCTAssertEqual(s.asked.paths.count, 1)

        let remaining = try XCTUnwrap(s.service.list().first)
        XCTAssertEqual(remaining.path, second.path)
        XCTAssertEqual(s.service.attempt(remaining), .alreadyAuthorized)
        XCTAssertEqual(s.asked.paths.count, 1, "no second panel for what the first grant covers")
        XCTAssertTrue(s.service.list().isEmpty)
    }

    func testAnUnrelatedFolderIsRefusedAndNothingIsStored() throws {
        let base = try temp(self)
        let wanted = base.appendingPathComponent("Notes/Sub", isDirectory: true)
        let other = base.appendingPathComponent("Elsewhere", isDirectory: true)
        let lookalike = base.appendingPathComponent("Not", isDirectory: true)
        for url in [wanted, other, lookalike] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

        let destination = Mem()
        try destination.set(try PendingAuthorizationList.encode([folderItem(wanted.path)]), forKey: PendingAuthorizationList.key)
        let s = try setup(destination: destination)
        for chosen in [other, lookalike] {
            s.asked.answer = chosen
            XCTAssertEqual(s.service.attempt(s.service.list()[0]), .wrongSelection(expected: "Sub"))
        }
        XCTAssertNil(s.defaults.object(forKey: "folderAccessBookmarks.v1"), "no grant was stored for a folder that does not cover the request")
        XCTAssertEqual(s.service.list().count, 1)
    }
}

// MARK: - 4. The menu follows the list

final class MenuFollowsTheListTests: XCTestCase {
    private func change<T>(_ read: @escaping () -> T, _ act: () -> Void) -> Int {
        var fired = 0
        withObservationTracking { _ = read() } onChange: { fired += 1 }
        act()
        return fired
    }

    func testTheListGoingFromEmptyToNotEmptyIsSeenWithNoRestart() throws {
        let store = Mem()
        let state = PendingAuthorizationsState(destination: store)
        XCTAssertFalse(state.hasPending)
        let fired = change({ state.items.isEmpty }) {
            try! store.set(try! PendingAuthorizationList.encode([folderItem("/a")]), forKey: PendingAuthorizationList.key)
            state.refresh()
        }
        XCTAssertEqual(fired, 1, "what the menu item watches changed")
        XCTAssertTrue(state.hasPending)
    }

    func testTheListGoingFromNotEmptyToEmptyIsSeenToo() throws {
        let store = Mem()
        try store.set(try PendingAuthorizationList.encode([folderItem("/a"), folderItem("/b")]), forKey: PendingAuthorizationList.key)
        let state = PendingAuthorizationsState(destination: store)
        XCTAssertEqual(state.items.count, 2)
        var fired = change({ state.items.isEmpty }) {
            try! PendingAuthorizationList.resolve(store: "folderAccessBookmarks.v1", path: "/a", in: store)
            state.refresh()
        }
        XCTAssertEqual(fired, 1)
        XCTAssertEqual(state.items.map(\.path), ["/b"])
        fired = change({ state.items.isEmpty }) {
            try! PendingAuthorizationList.resolve(store: "folderAccessBookmarks.v1", path: "/b", in: store)
            state.refresh()
        }
        XCTAssertEqual(fired, 1)
        XCTAssertFalse(state.hasPending)
    }

    func testReadingTheSameListAgainDisturbsNothing() throws {
        let store = Mem()
        try store.set(try PendingAuthorizationList.encode([folderItem("/a")]), forKey: PendingAuthorizationList.key)
        let state = PendingAuthorizationsState(destination: store)
        XCTAssertEqual(change({ state.items }) { state.refresh() }, 0)
    }

    func testTheMenuAndTheWindowReadTheSameState() throws {
        let app = try source("Glossa/PageFlowApp.swift")
        XCTAssertTrue(app.contains("@State private var pendingAuthorizations = PendingAuthorizationsModel.shared"))
        XCTAssertTrue(app.contains(".disabled(pendingAuthorizations.items.isEmpty)"))
        let view = try source("Glossa/Views/MigrationView.swift")
        XCTAssertTrue(view.contains("var items: [PendingAuthorization] { state.items }"), "the model's items are the observable state's")
        XCTAssertTrue(view.contains("func refresh() { state.refresh() }"))
        XCTAssertTrue(view.contains("        refresh()\n    }\n\n    private func service()"), "the list is read again after every attempt")
    }
}
