import XCTest
@testable import LegacyMigration

// The offer, the three choices and what each leaves behind. Every test uses an in-memory
// destination, an isolated UserDefaults suite in a temporary folder, or a temporary folder. None
// reads or writes the reader's real preferences or Application Support.

// MARK: - Helpers

private final class MemoryDestination: MigrationDestination {
    var store: [String: Any] = [:]
    var sets: [String] = []
    var removes: [String] = []
    var failOnSet: Int?
    func value(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any, forKey key: String) throws {
        sets.append(key)
        if let failOnSet, sets.count == failOnSet { throw LegacyMigrator.Failure(reason: "disk full") }
        store[key] = value
    }
    func remove(forKey key: String) throws { removes.append(key); store[key] = nil }
}

private struct UnreadableSource: LegacyPreferencesSource {
    func snapshot() throws -> [String: Any] { throw CocoaError(.fileReadNoPermission) }
}

private struct RecentEntry: Codable {
    var url: URL
    var securityScopedBookmarkData: Data?
}

private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

private let pageFlowSource: [String: Any] = [
    "settings.showTooltips": true,
    "settings.toolbarScale": 1.5,
    "documentViewStates.v2": json(["a": 1]),
    "bookmarks:/tmp/x.pdf": json([Int]()),
    "sessionRestore.v1": json(["windows": []]),
    "hasShownDefaultPDFPrompt": true,
    "NSWindow Frame Main": "1 2 3 4",
]

private let identity = AppIdentity.bundleIdentifier

private func coordinator(source: LegacyPreferencesSource, destination: MigrationDestination,
                         isGlossa: Bool = true, support: URL? = nil) -> LegacyMigrationCoordinator {
    LegacyMigrationCoordinator(source: source, destination: destination,
                               migrator: LegacyMigrator(planner: LegacyMigrationPlanner(inspector: LegacyBookmarkInspector(scoped: false))),
                               isGlossa: isGlossa, appVersion: "9.9", applicationSupport: support)
}

private func tempFolder(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-flow-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

private func repositoryRoot() -> URL {
    (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
}

private func swiftFiles(under folder: URL) -> [URL] {
    var result: [URL] = []
    if let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
        for case let url as URL in files where url.pathExtension == "swift" { result.append(url) }
    }
    return result
}

// MARK: - Identity

final class IdentityTests: XCTestCase {
    func testTheBundleIdentifierIsTheAgreedOneInEveryConfiguration() throws {
        XCTAssertEqual(AppIdentity.bundleIdentifier, "io.github.effe1209.Glossa")
        let project = try String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow.xcodeproj/project.pbxproj"), encoding: .utf8)
        let identifiers = project.components(separatedBy: "\n").filter { $0.contains("PRODUCT_BUNDLE_IDENTIFIER") }
        // Debug and Release of the app, and Release-Direct.
        XCTAssertEqual(identifiers.count, 3)
        for line in identifiers { XCTAssertTrue(line.contains("= io.github.effe1209.Glossa;"), line) }
        XCTAssertFalse(project.contains("com.raccoontechnologies"))
    }

    func testTheInfoPlistsTakeTheIdentifierFromTheBuildSettingsNotFromALiteral() throws {
        for name in ["PageFlow-Info.plist", "PageFlow-Direct-Info.plist"] {
            let text = try String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow/\(name)"), encoding: .utf8)
            XCTAssertTrue(text.contains("$(PRODUCT_BUNDLE_IDENTIFIER)"), name)
            XCTAssertFalse(text.contains("raccoontechnologies"), name)
        }
    }

    func testOnlyGlossaItselfIsOfferedTheImport() {
        XCTAssertTrue(AppIdentity.isGlossa(AppIdentity.bundleIdentifier))
        XCTAssertFalse(AppIdentity.isGlossa(AppIdentity.legacyBundleIdentifier))
        XCTAssertFalse(AppIdentity.isGlossa("io.github.effe1209.Glossa.RecoveryQA.1"))
        XCTAssertFalse(AppIdentity.isGlossa(nil))
    }

    func testThePageFlowIdentifierAppearsOnlyAsTheMigrationSourceAndInQAHarnesses() throws {
        let app = repositoryRoot().appendingPathComponent("PageFlow")
        for url in swiftFiles(under: app) {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("com.raccoontechnologies.PageFlow") else { continue }
            let path = url.path
            let allowed = path.contains("/PageFlow/Migration/") || path.contains("/PageFlow/Debug/")
            XCTAssertTrue(allowed, "\(url.lastPathComponent) names PageFlow's identifier outside the migration code")
        }
    }

    func testTheOldDomainIsNeverOpenedThroughUserDefaultsSuiteName() throws {
        for url in swiftFiles(under: repositoryRoot().appendingPathComponent("PageFlow/Migration")) {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.contains("UserDefaults(suiteName"), url.lastPathComponent)
            XCTAssertFalse(text.contains("removePersistentDomain"), url.lastPathComponent)
            XCTAssertFalse(text.contains("CFPreferencesSetValue"), url.lastPathComponent)
            XCTAssertFalse(text.contains("CFPreferencesSetAppValue"), url.lastPathComponent)
        }
    }

    func testTheDomainOfTheAppIsThatOfItsBundleIdentifier() {
        // `UserDefaults.standard` is the domain of the bundle identifier; AppDefaults hands that out outside tests.
        let source = try? String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow/Utilities/AppDefaults.swift"), encoding: .utf8)
        XCTAssertTrue(source?.contains("return .standard") == true)
        XCTAssertFalse(source?.contains("raccoontechnologies") == true)
    }
}

// MARK: - Detecting PageFlow's data and deciding whether to ask

final class OfferTests: XCTestCase {
    func testPageFlowDataIsDetectedAndSummarised() throws {
        let offer = coordinator(source: DictionarySource(values: pageFlowSource), destination: MemoryDestination()).evaluate()
        let summary = try XCTUnwrap(offer.summary)
        XCTAssertTrue(summary.hasAnythingToImport)
        XCTAssertEqual(summary.carriedOver.first { $0.title == "Settings" }?.count, 2)
        XCTAssertEqual(summary.carriedOver.first { $0.title == "Reading positions" }?.count, 1)
        XCTAssertEqual(summary.carriedOver.first { $0.title == "Page bookmarks" }?.count, 1)
        XCTAssertEqual(summary.leftBehind, 3, "the session, the prompt flag and the window frame stay behind")
    }

    func testOfferingNeverWritesAnything() {
        let destination = MemoryDestination()
        let source = DictionarySource(values: pageFlowSource)
        _ = coordinator(source: source, destination: destination).evaluate()
        _ = coordinator(source: source, destination: destination).evaluate()
        XCTAssertTrue(destination.sets.isEmpty)
        XCTAssertTrue(destination.removes.isEmpty)
        XCTAssertTrue(destination.store.isEmpty, "a launch alone never imports, records or marks anything")
    }

    func testNoOfferWhenThereIsNoPageFlowData() {
        let destination = MemoryDestination()
        XCTAssertEqual(coordinator(source: DictionarySource(values: [:]), destination: destination).evaluate(), .notNeeded(.noLegacyData))
        XCTAssertTrue(destination.sets.isEmpty)
    }

    func testNoOfferWhenEverythingInThePageFlowDataIsExcluded() {
        let source = DictionarySource(values: ["sessionRestore.v1": json([]), "NSWindow Frame Main": "x", "somethingNobodyListed": 1])
        XCTAssertEqual(coordinator(source: source, destination: MemoryDestination()).evaluate(), .notNeeded(.nothingToImport))
    }

    func testNoOfferWhenGlossaAlreadyHasEveryKey() {
        let destination = MemoryDestination()
        for key in ["settings.showTooltips", "settings.toolbarScale", "documentViewStates.v2", "bookmarks:/tmp/x.pdf"] { destination.store[key] = "mine" }
        XCTAssertEqual(coordinator(source: DictionarySource(values: pageFlowSource), destination: destination).evaluate(), .notNeeded(.nothingToImport))
    }

    func testNoOfferWhenNotRunningAsGlossa() {
        let destination = MemoryDestination()
        let source = CountingSource(pageFlowSource)
        XCTAssertEqual(coordinator(source: source, destination: destination, isGlossa: false).evaluate(), .notNeeded(.notGlossa))
        XCTAssertEqual(source.reads, 0, "another identity does not even read PageFlow's data")
    }

    func testNoOfferWhenTheSourceCannotBeRead() {
        let offer = coordinator(source: UnreadableSource(), destination: MemoryDestination()).evaluate()
        guard case .notNeeded(.sourceUnreadable) = offer else { return XCTFail("\(offer)") }
    }

    func testACompletedImportIsNotOfferedAgain() {
        let destination = MemoryDestination()
        let flow = coordinator(source: DictionarySource(values: pageFlowSource), destination: destination)
        guard case .imported = flow.choose(.importNow) else { return XCTFail("the import should run") }
        XCTAssertEqual(flow.evaluate(), .notNeeded(.alreadyMigrated))
    }
}

private final class CountingSource: LegacyPreferencesSource {
    let values: [String: Any]
    var reads = 0
    init(_ values: [String: Any]) { self.values = values }
    func snapshot() throws -> [String: Any] { reads += 1; return values }
}

// MARK: - The three choices

final class ChoiceTests: XCTestCase {
    func testImportWritesTheAllowedKeysAndTheMarkerLastAndLeavesPageFlowAlone() throws {
        let destination = MemoryDestination()
        let source = CountingSource(pageFlowSource)
        let before = NSDictionary(dictionary: source.values)
        let support = try tempFolder(self)

        let outcome = coordinator(source: source, destination: destination, support: support).choose(.importNow)
        guard case .imported(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(report.state, .applied)
        XCTAssertEqual(destination.store["settings.showTooltips"] as? Bool, true)
        XCTAssertNotNil(destination.store[MigrationMarker.key])
        XCTAssertEqual(destination.sets.last, MigrationMarker.key, "the marker is the last write")
        XCTAssertNil(destination.store["sessionRestore.v1"])
        XCTAssertNil(destination.store["hasShownDefaultPDFPrompt"])
        XCTAssertNil(destination.store[MigrationDeclined.key], "importing is not a refusal")
        XCTAssertTrue(destination.removes.isEmpty)
        XCTAssertTrue(NSDictionary(dictionary: source.values).isEqual(to: before as! [AnyHashable: Any]), "PageFlow's preferences are untouched")
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent("Glossa").path, isDirectory: &isDirectory) && isDirectory.boolValue,
                      "Glossa's folder is prepared")
    }

    func testNotNowWritesNothingAndTheOfferComesBack() {
        let destination = MemoryDestination()
        let source = DictionarySource(values: pageFlowSource)
        XCTAssertEqual(coordinator(source: source, destination: destination).choose(.notNow), .postponed)
        XCTAssertTrue(destination.sets.isEmpty)
        XCTAssertNil(destination.store[MigrationMarker.key], "no marker, as if nothing had been decided")
        XCTAssertNil(destination.store[MigrationDeclined.key])
        // The next launch: a fresh coordinator over the same preferences.
        XCTAssertNotNil(coordinator(source: source, destination: destination).evaluate().summary)
    }

    func testNeverRecordsTheDecisionImportsNothingAndIsNotOfferedAgain() throws {
        let destination = MemoryDestination()
        let source = CountingSource(pageFlowSource)
        let before = NSDictionary(dictionary: source.values)
        let flow = coordinator(source: source, destination: destination)
        XCTAssertEqual(flow.choose(.neverImport), .declinedForGood)
        XCTAssertEqual(Set(destination.store.keys), [MigrationDeclined.key], "only the decision is written")
        XCTAssertNil(destination.store[MigrationMarker.key], "a refusal is not a completed import")
        XCTAssertEqual(source.reads, 0)
        XCTAssertTrue(NSDictionary(dictionary: source.values).isEqual(to: before as! [AnyHashable: Any]))
        let record = try JSONDecoder().decode(MigrationDeclined.self, from: destination.store[MigrationDeclined.key] as! Data)
        XCTAssertEqual(record.version, MigrationDeclined.currentVersion)
        XCTAssertEqual(record.appVersion, "9.9")
        // The next launch, even with new data in PageFlow's preferences.
        var richer = pageFlowSource
        richer["settings.toolbarScale"] = 2.0
        XCTAssertEqual(coordinator(source: DictionarySource(values: richer), destination: destination).evaluate(), .notNeeded(.declined))
    }

    func testTheThreeChoicesLeaveDistinctPersistentTraces() {
        var traces: [MigrationChoice: Set<String>] = [:]
        for choice in MigrationChoice.allCases {
            let destination = MemoryDestination()
            _ = coordinator(source: DictionarySource(values: pageFlowSource), destination: destination).choose(choice)
            traces[choice] = Set(destination.store.keys.filter { $0.hasPrefix("glossa.migration.") })
        }
        XCTAssertEqual(traces[.notNow], [])
        XCTAssertEqual(traces[.neverImport], [MigrationDeclined.key])
        XCTAssertTrue(traces[.importNow]?.contains(MigrationMarker.key) == true)
        XCTAssertFalse(traces[.importNow]?.contains(MigrationDeclined.key) == true)
    }

    func testImportingTwiceDoesNothingTheSecondTime() {
        let destination = MemoryDestination()
        let flow = coordinator(source: DictionarySource(values: pageFlowSource), destination: destination)
        _ = flow.choose(.importNow)
        let writes = destination.sets.count
        let again = flow.choose(.importNow)
        guard case .imported(let report) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(report.state, .alreadyMigrated)
        XCTAssertEqual(destination.sets.count, writes, "no write the second time")
    }

    func testAKeyGlossaAlreadyHasIsNotOverwritten() throws {
        let destination = MemoryDestination()
        destination.store["settings.toolbarScale"] = 3.0
        let outcome = coordinator(source: DictionarySource(values: pageFlowSource), destination: destination).choose(.importNow)
        guard case .imported(let report) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(destination.store["settings.toolbarScale"] as? Double, 3.0)
        XCTAssertTrue(report.keptFromDestination.contains("settings.toolbarScale"))
        XCTAssertEqual(MigrationSummary(report).keptFromGlossa, 1)
    }

    func testAFailureLeavesNoMarkerNoKeysAndTheOfferStays() throws {
        let destination = MemoryDestination()
        destination.failOnSet = 3
        let support = try tempFolder(self)
        let source = DictionarySource(values: pageFlowSource)
        let outcome = coordinator(source: source, destination: destination, support: support).choose(.importNow)
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertNil(destination.store[MigrationMarker.key], "an interrupted import never looks completed")
        XCTAssertEqual(destination.store.count, 0, "what was written is taken back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Glossa").path), "no folder for an import that failed")
        XCTAssertNotNil(coordinator(source: source, destination: destination).evaluate().summary, "it is offered again")
        // And a retry succeeds.
        destination.failOnSet = nil
        guard case .imported = coordinator(source: source, destination: destination).choose(.importNow) else { return XCTFail("retry") }
    }

    func testAFailureToSaveTheRefusalIsReportedAndNothingIsRecorded() {
        let destination = MemoryDestination()
        destination.failOnSet = 1
        guard case .failed = coordinator(source: DictionarySource(values: pageFlowSource), destination: destination).choose(.neverImport) else { return XCTFail() }
        XCTAssertTrue(destination.store.isEmpty)
    }

    func testThePageFlowFolderInApplicationSupportIsNeverTouched() throws {
        let support = try tempFolder(self)
        let legacy = ApplicationSupportLocations.legacy(in: support)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Recovery"), withIntermediateDirectories: true)
        let note = legacy.appendingPathComponent("Recovery/draft.json")
        try Data("recovery".utf8).write(to: note)
        let before = try Data(contentsOf: note)

        _ = coordinator(source: DictionarySource(values: pageFlowSource), destination: MemoryDestination(), support: support).choose(.importNow)
        XCTAssertEqual(try Data(contentsOf: note), before)
        let names = try FileManager.default.contentsOfDirectory(atPath: legacy.path)
        XCTAssertEqual(names, ["Recovery"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ApplicationSupportLocations.glossa(in: support).path), [], "Glossa's folder is empty: nothing is copied")
    }

    func testImportingIntoARealDefaultsSuiteWritesOnlyThere() throws {
        let dir = try tempFolder(self)
        let defaults = UserDefaults(suiteName: dir.appendingPathComponent("glossa").path)!
        let flow = coordinator(source: DictionarySource(values: pageFlowSource), destination: UserDefaultsDestination(defaults: defaults))
        guard case .imported = flow.choose(.importNow) else { return XCTFail() }
        XCTAssertEqual(defaults.bool(forKey: "settings.showTooltips"), true)
        XCTAssertNotNil(defaults.data(forKey: MigrationMarker.key))
        XCTAssertNil(defaults.object(forKey: "sessionRestore.v1"))
    }
}

// MARK: - Bookmarks that no longer work

final class BookmarkAuthorizationTests: XCTestCase {
    private func recentSource(_ entries: [RecentEntry]) -> [String: Any] {
        ["recentFiles": try! JSONEncoder().encode(entries), "settings.showTooltips": true]
    }

    func testABookmarkThatDoesNotWorkIsListedWithItsPathAndNothingIsAuthorizedForTheReader() throws {
        let folder = try tempFolder(self)
        let good = folder.appendingPathComponent("good.pdf")
        let gone = folder.appendingPathComponent("gone.pdf")
        try Data("x".utf8).write(to: good)
        try Data("x".utf8).write(to: gone)
        let goodMark = try good.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let goneMark = try gone.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try FileManager.default.removeItem(at: gone)

        let destination = MemoryDestination()
        let source = recentSource([RecentEntry(url: good, securityScopedBookmarkData: goodMark),
                                   RecentEntry(url: gone, securityScopedBookmarkData: goneMark)])
        let flow = coordinator(source: source.isEmpty ? DictionarySource(values: [:]) : DictionarySource(values: source), destination: destination)
        guard case .imported(let report) = flow.choose(.importNow) else { return XCTFail() }

        let summary = MigrationSummary(report)
        XCTAssertEqual(summary.authorizations.map(\.path), [gone.path], "the file that cannot be reached is named")
        XCTAssertTrue(summary.needAttention.contains("Recent files"))
        XCTAssertNil(destination.store["folderAccessBookmarks.v1"], "no folder permission is created by the import")
        let pending = PendingAuthorizationList.read(from: destination)
        XCTAssertEqual(pending.map(\.path), [gone.path], "the path is kept for later")
        XCTAssertNotNil(destination.store[MigrationMarker.key])
    }

    func testAFolderThatCannotBeVerifiedIsNotCopiedAndItsPathIsKept() throws {
        let destination = MemoryDestination()
        let source: [String: Any] = ["folderAccessBookmarks.v1": ["/Users/example/Notes": Data("not a bookmark".utf8)], "settings.showTooltips": true]
        guard case .imported(let report) = coordinator(source: DictionarySource(values: source), destination: destination).choose(.importNow) else { return XCTFail() }
        XCTAssertNil(destination.store["folderAccessBookmarks.v1"], "no bookmark that was not verified is carried over")
        let pending = PendingAuthorizationList.read(from: destination)
        XCTAssertEqual(pending.map(\.path), ["/Users/example/Notes"])
        XCTAssertTrue(pending[0].isFolder)
        XCTAssertEqual(pending[0].action, BookmarkFinding.Action.dropped.rawValue)
        XCTAssertEqual(MigrationSummary(report).authorizations.count, 1)
    }

    func testAnEntryLeavesTheListOnlyWhenItIsResolved() throws {
        let destination = MemoryDestination()
        let source: [String: Any] = ["folderAccessBookmarks.v1": ["/a": Data("x".utf8), "/b": Data("y".utf8)], "settings.showTooltips": true]
        _ = coordinator(source: DictionarySource(values: source), destination: destination).choose(.importNow)
        XCTAssertEqual(PendingAuthorizationList.read(from: destination).map(\.path).sorted(), ["/a", "/b"])
        try PendingAuthorizationList.resolve(store: "folderAccessBookmarks.v1", path: "/a", in: destination)
        XCTAssertEqual(PendingAuthorizationList.read(from: destination).map(\.path), ["/b"])
        try PendingAuthorizationList.resolve(store: "folderAccessBookmarks.v1", path: "/b", in: destination)
        XCTAssertNil(destination.store[PendingAuthorizationList.key], "an empty list is not kept")
    }

    func testNothingIsListedWhenEveryBookmarkWorks() throws {
        let folder = try tempFolder(self)
        let file = folder.appendingPathComponent("a.pdf")
        try Data("x".utf8).write(to: file)
        let mark = try file.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let destination = MemoryDestination()
        _ = coordinator(source: DictionarySource(values: recentSource([RecentEntry(url: file, securityScopedBookmarkData: mark)])), destination: destination).choose(.importNow)
        XCTAssertNil(destination.store[PendingAuthorizationList.key])
    }

    func testTheListIsRolledBackWithTheRestWhenTheImportFails() throws {
        let destination = MemoryDestination()
        let source: [String: Any] = ["folderAccessBookmarks.v1": ["/a": Data("x".utf8)], "settings.showTooltips": true]
        // Writes: showTooltips (1), pending list (2), marker (3).
        destination.failOnSet = 3
        guard case .failed = coordinator(source: DictionarySource(values: source), destination: destination).choose(.importNow) else { return XCTFail() }
        XCTAssertTrue(destination.store.isEmpty, "neither the keys nor the list survive a failed import")
    }
}

// MARK: - Nothing runs without a choice

final class ConsentTests: XCTestCase {
    func testTheEngineRunsForRealOnlyInsideTheCoordinator() throws {
        let app = repositoryRoot().appendingPathComponent("PageFlow")
        for url in swiftFiles(under: app) {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("dryRun: false") {
                XCTAssertEqual(url.lastPathComponent, "LegacyMigrationCoordinator.swift", "\(url.lastPathComponent) runs the engine for real")
            }
        }
    }

    func testOnlyTheImportButtonAsksTheCoordinatorToImport() throws {
        let app = repositoryRoot().appendingPathComponent("PageFlow")
        for url in swiftFiles(under: app) {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains(".choose(.importNow)") {
                XCTAssertEqual(url.lastPathComponent, "MigrationView.swift", "\(url.lastPathComponent) imports without the reader asking")
            }
        }
    }

    func testTheOfferIsNotShownInATestHostOrToAnotherIdentity() throws {
        let presenter = try String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow/Migration/MigrationPresenter.swift"), encoding: .utf8)
        XCTAssertTrue(presenter.contains("!TestEnvironment.isRunningTests, AppIdentity.isGlossa()"))
    }
}
