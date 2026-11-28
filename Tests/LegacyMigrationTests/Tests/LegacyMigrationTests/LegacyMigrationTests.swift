import XCTest
@testable import LegacyMigration

// Every test here uses a temporary folder, an in-memory dictionary or a UserDefaults suite of its
// own, removed afterwards. None reads or writes the reader's real preferences.

// MARK: - Helpers

extension XCTestCase {
    /// UserDefaults kept in a file inside a temporary folder (a suite named by an absolute path), so
    /// nothing is left in the reader's Preferences folder and nothing of the reader's is read.
    fileprivate func suite() -> UserDefaults {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-migration-defaults-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return UserDefaults(suiteName: dir.appendingPathComponent("test").path)!
    }

    fileprivate func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-migration-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    fileprivate func file(_ name: String, in folder: URL, contents: String = "x") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

private func bookmark(_ url: URL) throws -> Data {
    try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
}

private struct RecentEntry: Codable, Equatable {
    var url: URL
    var securityScopedBookmarkData: Data?
}

private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }
private func encode<T: Encodable>(_ value: T) -> Data { try! JSONEncoder().encode(value) }

private let planner = LegacyMigrationPlanner(inspector: LegacyBookmarkInspector(scoped: false))
private let migrator = LegacyMigrator(planner: planner)

/// A destination that records what is done to it.
private final class RecordingDestination: MigrationDestination {
    var store: [String: Any] = [:]
    var sets: [String] = []
    var removes: [String] = []
    /// Throws on the n-th write (1-based), if set.
    var failOnSet: Int?
    func value(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any, forKey key: String) throws {
        sets.append(key)
        if let failOnSet, sets.count == failOnSet { throw LegacyMigrator.Failure(reason: "disk full") }
        store[key] = value
    }
    func remove(forKey key: String) throws { removes.append(key); store[key] = nil }
}

/// A source whose snapshot is a plain copy, with a counter, to see it is only read.
private final class CountingSource: LegacyPreferencesSource {
    let values: [String: Any]
    var reads = 0
    init(_ values: [String: Any]) { self.values = values }
    func snapshot() throws -> [String: Any] { reads += 1; return values }
}

private func sampleSource(recent: Data? = nil) -> [String: Any] {
    var values: [String: Any] = [
        "settings.showTooltips": true,
        "settings.toolbarScale": 1.5,
        "settings.markdownColorScheme": "system",
        "settings.markupPaletteVersion": "pastel-1",
        "settings.highlightPresets": json([["name": "Yellow", "hex": "#FFFF00"]]),
        "settings.customShortcuts": json([String: String]()),
        "glossa.tabs.scale": 1.0,
        "glossa.markup.layer.highlight.v1": json(["schema": 1, "custom": []]),
        "documentViewStates.v2": json(["a": 1]),
        "bookmarks:/tmp/x.pdf": json([Int]()),
        "epubNarrationRate": Float(1.25),
        // left behind on purpose
        "sessionRestore.v1": json(["windows": []]),
        "hasShownDefaultPDFPrompt": true,
        "NSWindow Frame Main": "1 2 3 4",
        "NSNavPanelExpandedSizeForOpenMode": "{880, 448}",
        "AppleActionOnDoubleClick": "Maximize",
        "somethingNobodyListed": 1,
    ]
    if let recent { values["recentFiles"] = recent }
    return values
}

// MARK: - 1. Dry run

final class DryRunTests: XCTestCase {
    func testADryRunWritesNothingAndReadsTheSourceOnly() throws {
        let source = CountingSource(sampleSource())
        let destination = RecordingDestination()
        destination.store["settings.showTooltips"] = false     // already there
        let before = NSDictionary(dictionary: source.values)
        let report = migrator.run(source: source, destination: destination, dryRun: true)
        XCTAssertEqual(report.state, .dryRun)
        XCTAssertTrue(destination.sets.isEmpty)
        XCTAssertTrue(destination.removes.isEmpty)
        XCTAssertNil(destination.store[MigrationMarker.key], "a dry run never writes the marker")
        XCTAssertEqual(destination.store.count, 1)
        XCTAssertEqual(source.reads, 1)
        XCTAssertTrue(before.isEqual(to: source.values), "the source is as it was")
        XCTAssertTrue(report.written.isEmpty)
        XCTAssertEqual(report.keptFromDestination, ["settings.showTooltips"])
        XCTAssertFalse(report.items(.transferable).isEmpty, "the report still says what would be copied")
    }

    func testADryRunOnARealFileLeavesItByteForByte() throws {
        let dir = try folder()
        let plist = dir.appendingPathComponent("old.plist")
        try (sampleSource() as NSDictionary).write(to: plist)
        let hash = try Data(contentsOf: plist)
        let attributes = try FileManager.default.attributesOfItem(atPath: plist.path)
        let report = migrator.run(source: PropertyListFileSource(url: plist), destination: RecordingDestination(), dryRun: true)
        XCTAssertEqual(report.state, .dryRun)
        XCTAssertEqual(try Data(contentsOf: plist), hash)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: plist.path)[.modificationDate] as? Date, attributes[.modificationDate] as? Date)
    }

    func testReadingAMissingDomainGivesNothingAndCreatesNothing() throws {
        let domain = "local.glossa.migrationtests.nonexistent.\(UUID().uuidString)"
        XCTAssertEqual(try CFPreferencesDomainSource(domain: domain).snapshot().count, 0)
        let path = NSHomeDirectory() + "/Library/Preferences/\(domain).plist"
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}

// MARK: - 2. Allowlist and excluded keys

final class AllowlistTests: XCTestCase {
    func testOnlyTheAllowedKeysAreCopiedAndTheRestIsLeftBehindWithAReason() {
        let report = migrator.run(source: DictionarySource(values: sampleSource()), destination: RecordingDestination(), dryRun: true)
        func category(_ key: String) -> MigrationCategory? { report.items.first { $0.sourceKey == key }?.category }
        for key in ["settings.showTooltips", "settings.toolbarScale", "settings.markdownColorScheme",
                    "settings.highlightPresets", "settings.customShortcuts", "glossa.tabs.scale", "glossa.markup.layer.highlight.v1",
                    "documentViewStates.v2", "bookmarks:/tmp/x.pdf", "epubNarrationRate"] {
            XCTAssertEqual(category(key), .transferable, key)
        }
        for key in ["sessionRestore.v1", "hasShownDefaultPDFPrompt", "NSWindow Frame Main", "NSNavPanelExpandedSizeForOpenMode",
                    "AppleActionOnDoubleClick", "somethingNobodyListed", "settings.markupPaletteVersion"] {
            XCTAssertEqual(category(key), .excluded, key)
            XCTAssertNil(report.items.first { $0.sourceKey == key }?.destinationKey)
        }
    }

    func testNothingExcludedIsEverWritten() {
        let destination = RecordingDestination()
        _ = migrator.run(source: DictionarySource(values: sampleSource()), destination: destination, dryRun: false)
        for key in ["sessionRestore.v1", "hasShownDefaultPDFPrompt", "NSWindow Frame Main", "AppleActionOnDoubleClick", "somethingNobodyListed"] {
            XCTAssertNil(destination.store[key], key)
        }
        XCTAssertNotNil(destination.store["settings.showTooltips"])
        XCTAssertNotNil(destination.store[MigrationMarker.key])
    }

    func testAnUnknownSettingIsExcludedWhateverItsTypeAndTheReportSaysWhy() {
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: [
            "settings.someFutureFlag": true, "settings.someFutureScale": 1.25, "settings.someFutureName": "x",
            "settings.someFutureList": ["a", "b"], "settings.someFutureBlob": Data([1, 2, 3]),
            "settings.markupPaletteVersion": "pastel-1",
            "settings.showTooltips": true,
        ]), destination: destination, dryRun: false)
        for key in ["settings.someFutureFlag", "settings.someFutureScale", "settings.someFutureName", "settings.someFutureList", "settings.someFutureBlob"] {
            let item = report.items.first { $0.sourceKey == key }
            XCTAssertEqual(item?.category, .excluded, key)
            XCTAssertNil(item?.destinationKey, key)
            XCTAssertTrue(item?.detail.contains("not on the settings allowlist") == true, "\(key): \(item?.detail ?? "")")
            XCTAssertNil(destination.store[key], "\(key) is not written")
        }
        let palette = report.items.first { $0.sourceKey == "settings.markupPaletteVersion" }
        XCTAssertEqual(palette?.category, .excluded)
        XCTAssertTrue(palette?.detail.contains("Glossa keeps its palettes in versioned layers") == true)
        XCTAssertNil(destination.store["settings.markupPaletteVersion"])
        XCTAssertEqual(destination.store["settings.showTooltips"] as? Bool, true, "a listed setting still goes through")
        XCTAssertEqual(report.written, ["settings.showTooltips"])
    }

    func testEveryListedSettingIsAKeyTheCodeReadsAndEveryKeyTheCodeReadsIsDecided() throws {
        // Compare the list with the app's own sources, so a preference added later cannot be
        // migrated, or forgotten, without this test saying so.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let appSources = root.appendingPathComponent("Glossa")
        let regex = try NSRegularExpression(pattern: #""(settings\.[A-Za-z0-9_.]+)""#)
        var used = Set<String>()
        let files = try XCTUnwrap(FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil))
        for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/Migration/") {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                used.insert((text as NSString).substring(with: match.range(at: 1)))
            }
        }
        XCTAssertFalse(used.isEmpty, "the scan found no settings keys: the path to the sources is wrong")
        let listed = Set(LegacyMigrationPlanner.knownSettings.keys)
        let decidedNotToMigrate = Set(LegacyMigrationPlanner.settingsNotMigrated.keys)
        XCTAssertEqual(used.subtracting(listed).subtracting(decidedNotToMigrate), [],
                       "a settings key the code uses is neither on the allowlist nor consciously left out")
        XCTAssertEqual(listed.subtracting(used), [], "a listed setting the code no longer uses")
        XCTAssertTrue(listed.isDisjoint(with: decidedNotToMigrate))
        XCTAssertEqual(listed.count, 25)
    }

    func testUnknownGlossaKeysAndDiagnosticCopiesAreExcluded() {
        let report = migrator.run(source: DictionarySource(values: [
            "glossa.somethingNew": 1, "glossa.markup.layer.highlight.v1.unreadable": Data([0]), "glossa.migration.fromPageFlow.v1": Data([0]),
        ]), destination: RecordingDestination(), dryRun: true)
        XCTAssertEqual(report.items.map(\.category), [.excluded, .excluded, .excluded])
    }
}

// MARK: - 8. Missing and malformed data

final class MalformedDataTests: XCTestCase {
    func testAWrongTypeIsInvalidAndNotCopied() {
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: [
            "settings.showTooltips": "yes",                       // should be a Boolean
            "settings.toolbarScale": true,                        // a Boolean is not a number
            "settings.markdownColorScheme": 3,                    // should be a string
            "settings.highlightPresets": Data("not json".utf8),   // should be JSON
            "settings.customShortcuts": "nope",                   // should be data
            "settings.markdownFontSize": Double.nan,
            "glossa.markup.layer.highlight.v1": json(["colors": []]),   // no schema number
            "documentViewStates.v2": Data([0xFF, 0xFE]),
        ]), destination: destination, dryRun: false)
        XCTAssertEqual(report.state, .applied)
        XCTAssertEqual(report.items(.invalid).count, 8)
        XCTAssertEqual(report.written, [])
        XCTAssertEqual(destination.store.keys.sorted(), [MigrationMarker.key], "only the marker: nothing invalid is copied")
    }

    func testAnEmptyOrMissingSourceImportsNothingAndStillCompletes() {
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: [:]), destination: destination, dryRun: false)
        XCTAssertEqual(report.state, .applied)
        XCTAssertTrue(report.items.isEmpty)
        XCTAssertNotNil(destination.store[MigrationMarker.key])
    }

    func testAnUnreadableSourceFailsWithoutWritingAnything() {
        let destination = RecordingDestination()
        let report = migrator.run(source: PropertyListFileSource(url: URL(fileURLWithPath: "/nonexistent/old.plist")), destination: destination, dryRun: false)
        guard case .failed = report.state else { return XCTFail("\(report.state)") }
        XCTAssertTrue(destination.sets.isEmpty)
        XCTAssertNil(destination.store[MigrationMarker.key])
    }

    func testMalformedRecentFilesAndRegistriesAreInvalid() {
        let report = migrator.run(source: DictionarySource(values: [
            "recentFiles": Data("{}".utf8), "pdfDocumentRegistry.v1": Data("[1,2]".utf8),
            "folderAccessBookmarks.v1": ["a": "not data"], "droppedImageBookmarks.v1": "nope",
        ]), destination: RecordingDestination(), dryRun: true)
        XCTAssertEqual(report.items(.invalid).count, 4)
    }
}

// MARK: - 5 and 6. Marker, idempotence, no duplicates

final class MarkerTests: XCTestCase {
    func testTheMarkerIsWrittenLastAndListsWhatWasImported() throws {
        let destination = RecordingDestination()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = migrator.run(source: DictionarySource(values: sampleSource()), destination: destination, dryRun: false,
                                  appVersion: "3.0", now: now)
        XCTAssertEqual(report.state, .applied)
        XCTAssertEqual(destination.sets.last, MigrationMarker.key, "the marker is written after everything else")
        let marker = try JSONDecoder().decode(MigrationMarker.self, from: destination.store[MigrationMarker.key] as! Data)
        XCTAssertEqual(marker.version, 1)
        XCTAssertEqual(marker.status, .completed)
        XCTAssertEqual(marker.sourceDomain, "com.raccoontechnologies.PageFlow")
        XCTAssertEqual(marker.appVersion, "3.0")
        XCTAssertEqual(marker.imported.sorted(), report.written.sorted())
        XCTAssertEqual(MigrationMarker.key, "glossa.migration.fromPageFlow.v1")
    }

    func testASecondRunDoesNothing() {
        let destination = RecordingDestination()
        let source = DictionarySource(values: sampleSource())
        _ = migrator.run(source: source, destination: destination, dryRun: false)
        let snapshot = NSDictionary(dictionary: destination.store)
        let writes = destination.sets.count
        let again = migrator.run(source: source, destination: destination, dryRun: false)
        XCTAssertEqual(again.state, .alreadyMigrated)
        XCTAssertEqual(destination.sets.count, writes)
        XCTAssertTrue(snapshot.isEqual(to: destination.store))
        XCTAssertEqual(migrator.run(source: source, destination: destination, dryRun: true).state, .alreadyMigrated)
    }

    func testTheDestinationWinsAndANewRunWithoutTheMarkerDoesNotDuplicateOrOverwrite() throws {
        let dir = try folder()
        let a = try file("a.pdf", in: dir), b = try file("b.pdf", in: dir)
        let recents = encode([RecentEntry(url: a, securityScopedBookmarkData: try bookmark(a)), RecentEntry(url: b, securityScopedBookmarkData: try bookmark(b))])
        let destination = RecordingDestination()
        destination.store["settings.showTooltips"] = false
        destination.store["settings.toolbarScale"] = 2.5
        let source = DictionarySource(values: sampleSource(recent: recents))
        let first = migrator.run(source: source, destination: destination, dryRun: false)
        XCTAssertEqual(destination.store["settings.showTooltips"] as? Bool, false, "what Glossa already had is not overwritten")
        XCTAssertEqual(destination.store["settings.toolbarScale"] as? Double, 2.5)
        XCTAssertTrue(first.keptFromDestination.contains("settings.showTooltips"))
        let stored = destination.store["recentFiles"] as! Data
        XCTAssertEqual(try JSONDecoder().decode([RecentEntry].self, from: stored).count, 2)

        // The marker is lost (or never written): importing again changes nothing.
        destination.store[MigrationMarker.key] = nil
        let before = NSDictionary(dictionary: destination.store.filter { $0.key != MigrationMarker.key })
        let second = migrator.run(source: source, destination: destination, dryRun: false)
        XCTAssertEqual(second.state, .applied)
        XCTAssertTrue(second.written.isEmpty, "everything was already there")
        XCTAssertTrue(before.isEqual(to: destination.store.filter { $0.key != MigrationMarker.key }))
        XCTAssertEqual(try JSONDecoder().decode([RecentEntry].self, from: destination.store["recentFiles"] as! Data).count, 2, "no duplicates")
    }

    func testTheMarkerWorksThroughRealUserDefaults() {
        let defaults = suite()
        let destination = UserDefaultsDestination(defaults: defaults)
        XCTAssertEqual(migrator.run(source: DictionarySource(values: sampleSource()), destination: destination, dryRun: false).state, .applied)
        XCTAssertNotNil(defaults.data(forKey: MigrationMarker.key))
        XCTAssertEqual(defaults.bool(forKey: "settings.showTooltips"), true)
        XCTAssertEqual(migrator.run(source: DictionarySource(values: sampleSource()), destination: destination, dryRun: false).state, .alreadyMigrated)
    }
}

// MARK: - 9. An error in the middle

final class InterruptionTests: XCTestCase {
    func testAFailureTakesBackWhatWasWrittenLeavesNoMarkerAndTheSourceIntact() throws {
        let values = sampleSource()
        let source = CountingSource(values)
        let destination = RecordingDestination()
        destination.store["settings.toolbarScale"] = 2.5       // the reader's own, kept
        destination.failOnSet = 4
        let before = NSDictionary(dictionary: values)
        let report = migrator.run(source: source, destination: destination, dryRun: false)
        guard case .failed = report.state else { return XCTFail("\(report.state)") }
        XCTAssertTrue(before.isEqual(to: source.values), "the source is untouched")
        XCTAssertNil(destination.store[MigrationMarker.key])
        XCTAssertEqual(destination.store.keys.sorted(), ["settings.toolbarScale"], "only what was there before is left")
        XCTAssertEqual(destination.store["settings.toolbarScale"] as? Double, 2.5)
        XCTAssertEqual(Set(destination.removes), Set(destination.sets.dropLast()), "it removed exactly the keys it had written")

        // The next run, with a healthy destination, completes.
        destination.failOnSet = nil
        destination.sets = []
        XCTAssertEqual(migrator.run(source: source, destination: destination, dryRun: false).state, .applied)
        XCTAssertNotNil(destination.store[MigrationMarker.key])
    }

    func testAFailureWritingTheMarkerAlsoTakesBackTheData() {
        let destination = RecordingDestination()
        let keys = migrator.run(source: DictionarySource(values: sampleSource()), destination: RecordingDestination(), dryRun: false).written.count
        destination.failOnSet = keys + 1                      // the marker is the last write
        let report = migrator.run(source: DictionarySource(values: sampleSource()), destination: destination, dryRun: false)
        guard case .failed = report.state else { return XCTFail("\(report.state)") }
        XCTAssertTrue(destination.store.isEmpty)
    }
}

// MARK: - 7. Bookmarks, one by one

final class BookmarkTests: XCTestCase {
    private let inspector = LegacyBookmarkInspector(scoped: false)

    func testAValidBookmarkIsValid() throws {
        let dir = try folder()
        let f = try file("a.pdf", in: dir)
        guard case .valid(let url) = inspector.inspect(try bookmark(f)) else { return XCTFail() }
        XCTAssertEqual(url.standardizedFileURL.lastPathComponent, "a.pdf")
    }

    func testAMovedFileMakesItsBookmarkStale() throws {
        let dir = try folder()
        let f = try file("a.pdf", in: dir)
        let data = try bookmark(f)
        let moved = dir.appendingPathComponent("renamed.pdf")
        try FileManager.default.moveItem(at: f, to: moved)
        guard case .stale(let url) = inspector.inspect(data) else { return XCTFail("\(inspector.inspect(data))") }
        XCTAssertEqual(url.lastPathComponent, "renamed.pdf")
    }

    func testADeletedFileOrGarbageDoesNotResolve() throws {
        let dir = try folder()
        let f = try file("a.pdf", in: dir)
        let data = try bookmark(f)
        try FileManager.default.removeItem(at: f)
        XCTAssertEqual(inspector.inspect(data), .unresolvable)
        XCTAssertEqual(inspector.inspect(Data("garbage".utf8)), .unresolvable)
    }

    func testAFileThatCannotBeReadIsUnreachable() throws {
        let dir = try folder()
        let f = try file("a.pdf", in: dir)
        let data = try bookmark(f)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: f.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.path) }
        guard case .unreachable = inspector.inspect(data) else { return XCTFail("\(inspector.inspect(data))") }
    }

    func testRecentFilesAreJudgedEntryByEntry() throws {
        let dir = try folder()
        let ok = try file("ok.pdf", in: dir), moved = try file("moved.pdf", in: dir), gone = try file("gone.pdf", in: dir), pathOnly = try file("path.pdf", in: dir)
        let okMark = try bookmark(ok), movedMark = try bookmark(moved), goneMark = try bookmark(gone)
        let renamed = dir.appendingPathComponent("moved-now.pdf")
        try FileManager.default.moveItem(at: moved, to: renamed)
        try FileManager.default.removeItem(at: gone)
        let recents = encode([
            RecentEntry(url: ok, securityScopedBookmarkData: okMark),
            RecentEntry(url: moved, securityScopedBookmarkData: movedMark),
            RecentEntry(url: gone, securityScopedBookmarkData: goneMark),
            RecentEntry(url: pathOnly, securityScopedBookmarkData: nil),
            RecentEntry(url: pathOnly, securityScopedBookmarkData: Data("garbage".utf8)),
        ])
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: ["recentFiles": recents]), destination: destination, dryRun: false)
        let item = try XCTUnwrap(report.items.first { $0.sourceKey == "recentFiles" })
        XCTAssertEqual(item.category, .needsVerification)

        let written = try JSONDecoder().decode([RecentEntry].self, from: destination.store["recentFiles"] as! Data)
        XCTAssertEqual(written.map { $0.url.lastPathComponent }, ["ok.pdf", "moved-now.pdf", "path.pdf", "path.pdf"], "the deleted one is left out")
        XCTAssertNotNil(written[0].securityScopedBookmarkData, "the valid bookmark is kept as it was")
        XCTAssertEqual(written[0].securityScopedBookmarkData, okMark)
        XCTAssertNil(written[1].securityScopedBookmarkData, "a stale bookmark is not carried over")
        XCTAssertNil(written[2].securityScopedBookmarkData)
        XCTAssertNil(written[3].securityScopedBookmarkData, "an unresolvable one is not carried over")

        let outcomes = report.bookmarkFindings.map { "\($0.subject.split(separator: "/").last!):\($0.outcome.rawValue):\($0.action.rawValue)" }
        XCTAssertEqual(outcomes, ["ok.pdf:valid:kept", "moved.pdf:stale:keptWithoutBookmark", "gone.pdf:unresolvable:dropped", "path.pdf:unresolvable:keptWithoutBookmark"])
        XCTAssertEqual(report.needsNewAuthorization.count, 3)
    }

    func testRecentFilesWithOnlyValidBookmarksPassThroughByteForByte() throws {
        let dir = try folder()
        let a = try file("a.pdf", in: dir)
        let recents = encode([RecentEntry(url: a, securityScopedBookmarkData: try bookmark(a))])
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: ["recentFiles": recents]), destination: destination, dryRun: false)
        XCTAssertEqual(destination.store["recentFiles"] as? Data, recents)
        XCTAssertEqual(report.items.first?.category, .transferable)
        XCTAssertTrue(report.needsNewAuthorization.isEmpty)
    }

    func testFolderAndImagePermissionsKeepOnlyTheBookmarksThatVerify() throws {
        let dir = try folder()
        let good = try folder(named: "good", in: dir), stale = try folder(named: "stale", in: dir), gone = try folder(named: "gone", in: dir)
        let goodMark = try bookmark(good), staleMark = try bookmark(stale), goneMark = try bookmark(gone)
        try FileManager.default.moveItem(at: stale, to: dir.appendingPathComponent("stale-now"))
        try FileManager.default.removeItem(at: gone)
        let access: [String: Data] = [good.path: goodMark, stale.path: staleMark, gone.path: goneMark]
        let images: [[String: Any]] = [["path": good.path, "bookmark": goodMark], ["path": gone.path, "bookmark": goneMark], ["path": "x"]]
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: ["folderAccessBookmarks.v1": access, "droppedImageBookmarks.v1": images]),
                                  destination: destination, dryRun: false)
        let kept = destination.store["folderAccessBookmarks.v1"] as? [String: Data]
        XCTAssertEqual(kept.map { Array($0.keys) }, [good.path])
        let keptImages = destination.store["droppedImageBookmarks.v1"] as? [[String: Any]]
        XCTAssertEqual(keptImages?.count, 1)
        XCTAssertEqual(report.items.filter { $0.category == .needsVerification }.count, 2)
        XCTAssertEqual(report.bookmarkFindings.filter { $0.store == "folderAccessBookmarks.v1" && $0.action == .dropped }.count, 2)
        XCTAssertTrue(report.bookmarkFindings.contains { $0.store == "droppedImageBookmarks.v1" && $0.subject.contains("(entry without") })
    }

    func testWhenNoBookmarkVerifiesNothingIsWrittenForThatStore() {
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: ["folderAccessBookmarks.v1": ["/nowhere": Data("x".utf8)]]),
                                  destination: destination, dryRun: false)
        XCTAssertNil(destination.store["folderAccessBookmarks.v1"])
        XCTAssertEqual(report.items.first?.category, .needsVerification)
        XCTAssertNil(report.items.first?.destinationKey)
    }

    func testABookmarkThatCannotBeVerifiedIsNeverCreatedOrAuthorizedByTheMigration() throws {
        // The planner only reads: after a run the files are as they were and nothing new was granted.
        let dir = try folder()
        let f = try file("a.pdf", in: dir)
        let before = try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date
        _ = migrator.run(source: DictionarySource(values: ["recentFiles": encode([RecentEntry(url: f, securityScopedBookmarkData: try bookmark(f))])]),
                         destination: RecordingDestination(), dryRun: false)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate] as? Date, before)
        XCTAssertEqual(try String(contentsOf: f), "x")
    }
}

private extension XCTestCase {
    func folder(named name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

// MARK: - 3 and 4. The PDF registry's key

final class RegistryKeyTests: XCTestCase {
    private func record(_ id: String, title: String, path: String) -> PDFDocumentRecord {
        PDFDocumentRecord(id: id, title: title, lastPath: path, bookmark: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testTheKeysAreNamedAsAgreed() {
        XCTAssertEqual(PDFDocumentRegistry.storageKey, "glossa.pdfDocumentRegistry.v1")
        XCTAssertEqual(PDFDocumentRegistry.legacyStorageKey, "pdfDocumentRegistry.v1")
    }

    func testTheGlossaKeyWinsOverTheLegacyOne() {
        let defaults = suite()
        defaults.set(encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")]), forKey: PDFDocumentRegistry.legacyStorageKey)
        defaults.set(encode(["0123456789abcdef": record("0123456789abcdef", title: "New", path: "/new.pdf")]), forKey: PDFDocumentRegistry.storageKey)
        let registry = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(registry.record(for: "0123456789abcdef")?.title, "New")
    }

    func testTheLegacyKeyIsReadWhenTheNewOneIsMissing() {
        let defaults = suite()
        defaults.set(encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")]), forKey: PDFDocumentRegistry.legacyStorageKey)
        let registry = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(registry.record(for: "0123456789abcdef")?.title, "Old")
        XCTAssertNil(defaults.data(forKey: PDFDocumentRegistry.storageKey), "reading alone writes nothing")
    }

    func testANewKeyThatIsPresentButCorruptIsNotReplacedByTheLegacyOneAndNothingIsOverwritten() throws {
        let defaults = suite()
        let legacy = encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")])
        let corrupt = Data("{ this is not a registry".utf8)
        defaults.set(legacy, forKey: PDFDocumentRegistry.legacyStorageKey)
        defaults.set(corrupt, forKey: PDFDocumentRegistry.storageKey)
        let dir = try folder()
        let pdf = try file("doc.pdf", in: dir)

        let registry = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(registry.issue, .unreadable, "the problem is reported")
        XCTAssertNil(registry.record(for: "0123456789abcdef"), "the older registry does not stand in for it")
        XCTAssertEqual(registry.count, 0)

        // The app goes on working for this launch, in memory only...
        registry.register(id: "fedcba9876543210", url: pdf, title: "Fresh")
        XCTAssertEqual(registry.record(for: "fedcba9876543210")?.title, "Fresh")
        // ...and neither value was touched.
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.storageKey), corrupt, "the corrupt value is not overwritten")
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.legacyStorageKey), legacy, "the legacy value is not touched")
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(PDFDocumentRegistry.unreadableKeyPrefix) }.count, 0)
        XCTAssertEqual(PDFDocumentRegistry(defaults: defaults, scoped: false).issue, .unreadable, "it is still reported at the next launch")
    }

    func testANewKeyOfTheWrongTypeIsAlsoUnreadableAndLeftAlone() {
        let defaults = suite()
        let legacy = encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")])
        defaults.set(legacy, forKey: PDFDocumentRegistry.legacyStorageKey)
        defaults.set("not data at all", forKey: PDFDocumentRegistry.storageKey)
        let registry = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(registry.issue, .unreadable)
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(defaults.string(forKey: PDFDocumentRegistry.storageKey), "not data at all")
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.legacyStorageKey), legacy)
    }

    func testRecoveryIsExplicitKeepsTheUnreadableValueAndLeavesTheLegacyKeyAlone() throws {
        let defaults = suite()
        let legacy = encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")])
        let corrupt = Data("{ this is not a registry".utf8)
        defaults.set(legacy, forKey: PDFDocumentRegistry.legacyStorageKey)
        defaults.set(corrupt, forKey: PDFDocumentRegistry.storageKey)
        let registry = PDFDocumentRegistry(defaults: defaults, scoped: false)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(registry.recoverFromLegacy(now: now))
        XCTAssertNil(registry.issue)
        XCTAssertEqual(registry.record(for: "0123456789abcdef")?.title, "Old")
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.legacyStorageKey), legacy, "the legacy key is not touched")
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.unreadableKeyPrefix + "1800000000"), corrupt, "the unreadable value is kept")
        XCTAssertEqual(PDFDocumentRegistry(defaults: defaults, scoped: false).record(for: "0123456789abcdef")?.title, "Old", "and now it is saved")
        XCTAssertFalse(registry.recoverFromLegacy(now: now), "nothing left to recover")
    }

    func testRecoveryDoesNothingWithoutAReadableLegacyRegistryOrWithoutAnIssue() {
        let defaults = suite()
        let corrupt = Data("nope".utf8)
        defaults.set(corrupt, forKey: PDFDocumentRegistry.storageKey)
        defaults.set(Data("also nope".utf8), forKey: PDFDocumentRegistry.legacyStorageKey)
        let registry = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertFalse(registry.recoverFromLegacy())
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.storageKey), corrupt)
        XCTAssertEqual(registry.issue, .unreadable)
        XCTAssertFalse(PDFDocumentRegistry(defaults: suite(), scoped: false).recoverFromLegacy(), "a registry with no issue has nothing to recover")
    }

    private struct SaveFailure: Error {}

    private func unreadableSetup() -> (UserDefaults, legacy: Data, corrupt: Data, PDFDocumentRegistry) {
        let defaults = suite()
        let legacy = encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")])
        let corrupt = Data("{ this is not a registry".utf8)
        defaults.set(legacy, forKey: PDFDocumentRegistry.legacyStorageKey)
        defaults.set(corrupt, forKey: PDFDocumentRegistry.storageKey)
        return (defaults, legacy, corrupt, PDFDocumentRegistry(defaults: defaults, scoped: false))
    }

    func testAFailureEncodingTheRecoveredRegistryChangesNothing() {
        let (defaults, legacy, corrupt, registry) = unreadableSetup()
        XCTAssertFalse(registry.recoverFromLegacy(now: Date(timeIntervalSince1970: 1_800_000_000), encode: { _ in throw SaveFailure() }))
        XCTAssertEqual(registry.issue, .unreadable, "still reported, so the user can retry")
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.storageKey), corrupt, "the original value is intact")
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.legacyStorageKey), legacy, "the legacy registry is not deleted")
        XCTAssertNil(defaults.object(forKey: PDFDocumentRegistry.unreadableKeyPrefix + "1800000000"), "nothing was set aside for a recovery that never began")
    }

    func testARecoveredRegistryThatDoesNotReadBackIsNotSavedAndTheOriginalSurvives() {
        let (defaults, legacy, corrupt, registry) = unreadableSetup()
        XCTAssertFalse(registry.recoverFromLegacy(now: Date(timeIntervalSince1970: 1_800_000_000), encode: { _ in Data("garbage".utf8) }))
        XCTAssertEqual(registry.issue, .unreadable)
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.storageKey), corrupt)
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.legacyStorageKey), legacy)
        XCTAssertEqual(registry.count, 0)
    }

    func testAFailedRecoveryCanBeRetriedAndThenSucceeds() {
        let (defaults, legacy, corrupt, registry) = unreadableSetup()
        XCTAssertFalse(registry.recoverFromLegacy(encode: { _ in throw SaveFailure() }))
        XCTAssertTrue(registry.recoverFromLegacy(now: Date(timeIntervalSince1970: 1_800_000_000)))
        XCTAssertNil(registry.issue)
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.unreadableKeyPrefix + "1800000000"), corrupt, "the unreadable copy is kept")
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.legacyStorageKey), legacy)
    }

    func testRecoveryNeverStartsOnItsOwn() throws {
        // Loading a registry with an unreadable value does not recover it...
        let (defaults, _, corrupt, registry) = unreadableSetup()
        _ = registry.record(for: "0123456789abcdef")
        _ = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.storageKey), corrupt)
        XCTAssertEqual(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(PDFDocumentRegistry.unreadableKeyPrefix) }.count, 0)

        // ...and no code of the app calls it yet: only the definition mentions it.
        let root = URL(fileURLWithPath: #filePath)
        let appSources = (0..<5).reduce(root) { url, _ in url.deletingLastPathComponent() }.appendingPathComponent("Glossa")
        var callers: [String] = []
        if let files = FileManager.default.enumerator(at: appSources, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "PDFDocumentRegistry.swift" {
                if let text = try? String(contentsOf: url, encoding: .utf8), text.contains("recoverFromLegacy(") { callers.append(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(callers, [], "nothing in the app may call recoverFromLegacy() until an interface asks the reader")
    }

    func testAnUnreadableLegacyRegistryWithNoNewKeyIsEmptyAndNothingIsWritten() {
        let defaults = suite()
        let junk = Data("junk".utf8)
        defaults.set(junk, forKey: PDFDocumentRegistry.legacyStorageKey)
        let registry = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(registry.count, 0)
        XCTAssertNil(registry.issue)
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.legacyStorageKey), junk)
        XCTAssertNil(defaults.object(forKey: PDFDocumentRegistry.storageKey))
    }

    func testNewWritesGoToTheGlossaKeyAndTheLegacyKeyIsNeverTouched() throws {
        let defaults = suite()
        let legacy = encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")])
        defaults.set(legacy, forKey: PDFDocumentRegistry.legacyStorageKey)
        let dir = try folder()
        let pdf = try file("doc.pdf", in: dir)
        let registry = PDFDocumentRegistry(defaults: defaults, scoped: false)
        registry.register(id: "fedcba9876543210", url: pdf, title: "Fresh")
        XCTAssertEqual(defaults.data(forKey: PDFDocumentRegistry.legacyStorageKey), legacy, "the legacy key is left exactly as it was")
        let written = try JSONDecoder().decode([String: PDFDocumentRecord].self, from: try XCTUnwrap(defaults.data(forKey: PDFDocumentRegistry.storageKey)))
        XCTAssertEqual(Set(written.keys), ["0123456789abcdef", "fedcba9876543210"], "what was read from the legacy key is carried into the new one")

        // From then on the new key is the registry, and a change of the legacy one does not show.
        defaults.set(Data("[]".utf8), forKey: PDFDocumentRegistry.legacyStorageKey)
        XCTAssertEqual(PDFDocumentRegistry(defaults: defaults, scoped: false).count, 2)
    }

    func testTheRegistryBehavesAsBeforeForADocumentTheNewKeyHolds() throws {
        let defaults = suite()
        let dir = try folder()
        let pdf = try file("doc.pdf", in: dir)
        PDFDocumentRegistry(defaults: defaults, scoped: false).register(id: "0123456789abcdef", url: pdf, title: "Kept")
        let again = PDFDocumentRegistry(defaults: defaults, scoped: false)
        XCTAssertEqual(again.record(for: "0123456789abcdef")?.title, "Kept")
        XCTAssertEqual(again.locate(id: "0123456789abcdef")?.url.lastPathComponent, "doc.pdf")
    }

    func testTheMigrationCopiesTheLegacyRegistryUnderTheNewNameAndStripsOnlyBadBookmarks() throws {
        let dir = try folder()
        let good = try file("good.pdf", in: dir), gone = try file("gone.pdf", in: dir)
        let goodMark = try bookmark(good), goneMark = try bookmark(gone)
        try FileManager.default.removeItem(at: gone)
        var a = record("aaaaaaaaaaaaaaaa", title: "Good", path: good.path); a.bookmark = goodMark
        var b = record("bbbbbbbbbbbbbbbb", title: "Gone", path: gone.path); b.bookmark = goneMark
        b.notes = [.init(path: "/x.md", bookmark: Data("garbage".utf8))]
        let legacy = encode([a.id: a, b.id: b])
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: [PDFDocumentRegistry.legacyStorageKey: legacy]), destination: destination, dryRun: false)
        XCTAssertNil(destination.store[PDFDocumentRegistry.legacyStorageKey], "it is written under the Glossa name only")
        let moved = try JSONDecoder().decode([String: PDFDocumentRecord].self, from: try XCTUnwrap(destination.store[PDFDocumentRegistry.storageKey] as? Data))
        XCTAssertEqual(moved["aaaaaaaaaaaaaaaa"]?.bookmark, goodMark)
        XCTAssertNil(moved["bbbbbbbbbbbbbbbb"]?.bookmark)
        XCTAssertNil(moved["bbbbbbbbbbbbbbbb"]?.notes.first?.bookmark)
        XCTAssertEqual(moved["bbbbbbbbbbbbbbbb"]?.lastPath, gone.path, "the record stays, to be found again by its path")
        XCTAssertEqual(report.items.first { $0.sourceKey == PDFDocumentRegistry.legacyStorageKey }?.category, .needsVerification)
        XCTAssertEqual(report.items.first?.destinationKey, PDFDocumentRegistry.storageKey)
    }

    func testAnUnreadableRegistryAlreadyInTheDestinationIsNotOverwrittenByTheImport() {
        let corrupt = Data("{ not a registry".utf8)
        let destination = RecordingDestination()
        destination.store[PDFDocumentRegistry.storageKey] = corrupt
        let legacy = encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")])
        let report = migrator.run(source: DictionarySource(values: [PDFDocumentRegistry.legacyStorageKey: legacy]), destination: destination, dryRun: false)
        XCTAssertEqual(destination.store[PDFDocumentRegistry.storageKey] as? Data, corrupt)
        XCTAssertTrue(report.keptFromDestination.contains(PDFDocumentRegistry.storageKey))
        XCTAssertFalse(report.written.contains(PDFDocumentRegistry.storageKey))
    }

    func testAnUnreadableGlossaRegistryInTheSourceIsReportedAndTheLegacyOneDoesNotStandInForIt() {
        let legacy = encode(["0123456789abcdef": record("0123456789abcdef", title: "Old", path: "/old.pdf")])
        let destination = RecordingDestination()
        let report = migrator.run(source: DictionarySource(values: [
            PDFDocumentRegistry.storageKey: Data("{ not a registry".utf8), PDFDocumentRegistry.legacyStorageKey: legacy,
        ]), destination: destination, dryRun: false)
        func item(_ key: String) -> MigrationItem? { report.items.first { $0.sourceKey == key } }
        XCTAssertEqual(item(PDFDocumentRegistry.storageKey)?.category, .invalid)
        XCTAssertEqual(item(PDFDocumentRegistry.legacyStorageKey)?.category, .excluded)
        XCTAssertTrue(item(PDFDocumentRegistry.legacyStorageKey)?.detail.contains("does not stand in") == true)
        XCTAssertNil(destination.store[PDFDocumentRegistry.storageKey], "no registry is written: nothing is replaced by an older one")
    }

    func testWhenTheSourceHasBothRegistryKeysTheGlossaOneIsTheOneCopied() {
        let report = migrator.run(source: DictionarySource(values: [
            PDFDocumentRegistry.legacyStorageKey: encode([String: PDFDocumentRecord]()),
            PDFDocumentRegistry.storageKey: encode([String: PDFDocumentRecord]()),
        ]), destination: RecordingDestination(), dryRun: true)
        func category(_ key: String) -> MigrationCategory? { report.items.first { $0.sourceKey == key }?.category }
        XCTAssertEqual(category(PDFDocumentRegistry.storageKey), .transferable)
        XCTAssertEqual(category(PDFDocumentRegistry.legacyStorageKey), .excluded)
    }
}
