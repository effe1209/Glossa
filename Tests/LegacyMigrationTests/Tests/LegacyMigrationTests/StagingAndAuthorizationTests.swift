import XCTest
import CryptoKit
@testable import LegacyMigration

// Phase 8: our own staging folders are removed when the copy will never use them, and the list of
// permissions to allow again is not lost behind an offer. Temporary folders and in-memory preferences only.

private final class Mem: MigrationDestination {
    var store: [String: Any] = [:]
    var failKey: String?
    func value(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any, forKey key: String) throws {
        if key == failKey { throw LegacyMigrator.Failure(reason: "disk full") }
        store[key] = value
    }
    func remove(forKey key: String) throws { store[key] = nil }
}

private func repositoryRoot() -> URL { (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() } }
private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func names(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
private func stagings(_ url: URL) -> [String] { names(url).filter { $0.hasPrefix(".import-staging-") } }

private func tree(_ root: URL) -> [String] {
    var lines: [String] = []
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
        for case let url as URL in files {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            lines.append("\(url.path.dropFirst(root.path.count))|\(isDirectory ? "-" : sha((try? Data(contentsOf: url)) ?? Data()))")
        }
    }
    return lines.sorted()
}

private struct Env {
    let base: URL
    let dest = Mem()
    var paths: ApplicationSupportPaths { ApplicationSupportPaths(base: base) }

    func put(_ data: Data, _ name: String, _ category: ApplicationSupportPaths.Category) throws {
        let folder = paths.legacyDirectory(for: category)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }

    /// A PageFlow folder whose only file is not sound (not JSON): the scan finds nothing to copy.
    func fillWithUnsoundFile() throws { try put(Data("not json".utf8), UUID().uuidString + ".json", .recovery) }

    func fillWithSoundFile() throws {
        let object: [String: Any] = ["path": "/b.epub", "highlights": [], "bookmarks": [], "updatedAt": 1.0, "identifier": NSNull()]
        try put(try JSONSerialization.data(withJSONObject: object), sha(Data("path:/b.epub".utf8)) + ".json", .epubAnnotations)
    }

    func leaveStaging(_ name: String = ".import-staging-OLD") throws {
        let folder = paths.glossaRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Recovery"), withIntermediateDirectories: true)
        try Data("half".utf8).write(to: folder.appendingPathComponent("Recovery/half.json"))
    }

    func coordinator(sandboxed: Bool = false) -> CombinedMigrationCoordinator {
        var files = AppSupportMigrator(paths: ApplicationSupportPaths(base: base, legacyIsReachable: !sandboxed))
        files.availableSpace = { _ in Int64.max / 4 }
        files.appVersion = "9.9"
        let preferences = LegacyMigrationCoordinator(
            source: DictionarySource(values: [:]), destination: dest,
            migrator: LegacyMigrator(planner: LegacyMigrationPlanner(inspector: LegacyBookmarkInspector(scoped: false))),
            isGlossa: true, isSandboxed: sandboxed, appVersion: "9.9", applicationSupport: base)
        return CombinedMigrationCoordinator(preferences: preferences, files: files)
    }
}

private func env(_ test: XCTestCase) throws -> Env {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-staging-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    return Env(base: base)
}

// MARK: - M2: staging folders

final class StagingCleanupTests: XCTestCase {
    func testNothingSoundToCopyRemovesAnEarlierRunsStaging() throws {
        let e = try env(self)
        try e.fillWithUnsoundFile()
        try e.leaveStaging()
        try Data("mine".utf8).write(to: e.paths.glossaRoot.appendingPathComponent("keep.txt"))
        let legacyBefore = tree(e.paths.legacyRoot)

        let report = e.coordinator().files.run()
        XCTAssertEqual(report.state, .completed, "only a permanently invalid file: concluded")
        XCTAssertEqual(stagings(e.paths.glossaRoot), [], "the leftover is gone")
        XCTAssertEqual(names(e.paths.glossaRoot), [".migration-appsupport-v1.json", "keep.txt"], "Glossa's own file is untouched; the marker records the skipped file")
        XCTAssertEqual(tree(e.paths.legacyRoot), legacyBefore, "PageFlow's folder is untouched")
    }

    func testARunThatHasThingsToCopyStillStartsOverAsBefore() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        try e.leaveStaging()
        XCTAssertEqual(e.coordinator().files.run().state, .completed)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
    }

    func testRefusingForGoodRemovesTheStagingAfterTheRefusalIsSaved() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        try e.leaveStaging()
        try e.leaveStaging(".import-staging-OTHER")
        try Data("mine".utf8).write(to: e.paths.glossaRoot.appendingPathComponent("keep.txt"))
        let legacyBefore = tree(e.paths.legacyRoot)
        let coordinator = e.coordinator()
        XCTAssertEqual(coordinator.evaluate().files.offer?.interrupted, true)

        let outcome = coordinator.choose(.neverImport)
        XCTAssertTrue(outcome.declinedFiles)
        XCTAssertNotNil(e.dest.value(forKey: AppSupportDeclined.key))
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
        XCTAssertEqual(names(e.paths.glossaRoot), ["keep.txt"])
        XCTAssertEqual(tree(e.paths.legacyRoot), legacyBefore)
        XCTAssertNil(coordinator.evaluate().files.offer, "and it is not offered again")
    }

    func testIfTheRefusalCannotBeSavedTheStagingStays() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        try e.leaveStaging()
        e.dest.failKey = AppSupportDeclined.key
        let outcome = e.coordinator().choose(.neverImport)
        XCTAssertFalse(outcome.declinedFiles)
        XCTAssertNotNil(outcome.failure)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [".import-staging-OLD"], "nothing is cleaned for a refusal that was not recorded")
    }

    func testNotNowLeavesTheStagingAndTheOfferSaysItWasInterrupted() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        try e.leaveStaging()
        let coordinator = e.coordinator()
        XCTAssertTrue(coordinator.choose(.notNow).postponed)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [".import-staging-OLD"], "postponing changes nothing")
        XCTAssertEqual(coordinator.evaluate().files.offer?.interrupted, true)
    }

    func testLookingAtTheOfferNeverCleansAnything() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        try e.leaveStaging()
        let before = tree(e.base)
        _ = e.coordinator().evaluate()
        _ = e.coordinator().files.status()
        XCTAssertEqual(tree(e.base), before, "evaluating is read-only")
    }

    func testOnlyRealFoldersInGlossasRootGo() throws {
        let e = try env(self)
        try e.fillWithUnsoundFile()
        let outside = e.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.createDirectory(at: e.paths.glossaRoot, withIntermediateDirectories: true)
        let link = e.paths.glossaRoot.appendingPathComponent(".import-staging-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let plainFile = e.paths.glossaRoot.appendingPathComponent(".import-staging-file")
        try Data("a file, not a folder".utf8).write(to: plainFile)
        let notOurs = e.paths.glossaRoot.appendingPathComponent("import-staging-nope", isDirectory: true)
        try FileManager.default.createDirectory(at: notOurs, withIntermediateDirectories: true)
        try e.leaveStaging()

        XCTAssertEqual(e.coordinator().files.removeOwnStaging(), 1)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "a link stays")
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("precious".utf8), "and what it points to")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plainFile.path), "a file with the name is not a staging folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: notOurs.path))
        XCTAssertEqual(stagings(e.paths.glossaRoot).sorted(), [".import-staging-file", ".import-staging-link"])
    }

    func testAfterTheCopyIsRecordedNothingIsCleaned() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        XCTAssertEqual(e.coordinator().files.run().state, .completed)
        try e.leaveStaging()
        XCTAssertEqual(e.coordinator().files.removeOwnStaging(), 0, "with a marker the folder is not ours to tidy")
        XCTAssertEqual(stagings(e.paths.glossaRoot), [".import-staging-OLD"])
    }

    func testASandboxedBuildTouchesNothing() throws {
        let e = try env(self)
        try e.leaveStaging()
        XCTAssertEqual(e.coordinator(sandboxed: true).files.removeOwnStaging(), 0)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [".import-staging-OLD"])
    }

    func testNothingToCopyCreatesNoFolderInGlossasRoot() throws {
        let e = try env(self)
        try FileManager.default.createDirectory(at: e.paths.legacyDirectory(for: .recovery), withIntermediateDirectories: true)
        XCTAssertEqual(e.coordinator().files.run().state, .nothingToCopy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path))
    }
}

// MARK: - Orphan staging with no offer

final class OrphanStagingTests: XCTestCase {
    private let hour: TimeInterval = 3600

    private func age(_ url: URL, by seconds: TimeInterval) throws {
        let date = Date().addingTimeInterval(-seconds)
        for item in [url, url.appendingPathComponent("Recovery")] {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: item.path)
        }
    }

    /// An old staging folder, in a world where nothing sound is left to copy.
    private func oldStaging(_ e: Env, name: String = ".import-staging-OLD") throws {
        try e.leaveStaging(name)
        try age(e.paths.glossaRoot.appendingPathComponent(name), by: 5 * hour)
    }

    func testWithNothingToCopyAnOldStagingGoes() throws {
        let e = try env(self)
        try FileManager.default.createDirectory(at: e.paths.legacyDirectory(for: .recovery), withIntermediateDirectories: true)
        try oldStaging(e)
        try Data("mine".utf8).write(to: e.paths.glossaRoot.appendingPathComponent("keep.txt"))
        let legacyBefore = tree(e.paths.legacyRoot)
        XCTAssertNil(e.coordinator().evaluate().files.offer, "an empty PageFlow folder: no offer")
        XCTAssertEqual(e.coordinator().tidyOrphanStaging(), 1)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
        XCTAssertEqual(names(e.paths.glossaRoot), ["keep.txt"])
        XCTAssertEqual(tree(e.paths.legacyRoot), legacyBefore)
    }

    func testAlsoWhenPageFlowHasNoFolderAtAll() throws {
        let e = try env(self)
        try oldStaging(e)
        XCTAssertEqual(e.coordinator().tidyOrphanStaging(), 1)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
    }

    func testAlsoWhenTheFilesWereRefusedOrOnlyLinksRemain() throws {
        let refused = try env(self)
        try refused.fillWithSoundFile()
        try oldStaging(refused)
        try refused.dest.set(Data("x".utf8), forKey: AppSupportDeclined.key)
        XCTAssertEqual(refused.coordinator().tidyOrphanStaging(), 1)

        let preferencesRefused = try env(self)
        try preferencesRefused.fillWithSoundFile()
        try oldStaging(preferencesRefused)
        try preferencesRefused.dest.set(Data("x".utf8), forKey: MigrationDeclined.key)
        XCTAssertEqual(preferencesRefused.coordinator().tidyOrphanStaging(), 1)

        let linked = try env(self)
        try FileManager.default.createDirectory(at: linked.paths.legacyRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linked.paths.legacyRoot, withDestinationURL: linked.base.appendingPathComponent("elsewhere"))
        try oldStaging(linked)
        XCTAssertEqual(linked.coordinator().tidyOrphanStaging(), 1)
    }

    func testWithAnOfferNothingIsRemoved() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        try oldStaging(e)
        XCTAssertNotNil(e.coordinator().evaluate().files.offer)
        XCTAssertEqual(e.coordinator().tidyOrphanStaging(), 0)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [".import-staging-OLD"])
    }

    func testARecentStagingIsLeftInCaseAnotherCopyIsRunning() throws {
        let e = try env(self)
        try e.leaveStaging()                       // just made
        XCTAssertEqual(e.coordinator().tidyOrphanStaging(), 0)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [".import-staging-OLD"])
        XCTAssertEqual(e.coordinator().tidyOrphanStaging(now: Date().addingTimeInterval(2 * hour)), 1, "and goes once it is old enough")
    }

    func testAFolderWhoseSubfolderWasJustWrittenIsRecent() throws {
        let e = try env(self)
        try oldStaging(e)
        let folder = e.paths.glossaRoot.appendingPathComponent(".import-staging-OLD")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.appendingPathComponent("Recovery").path)
        XCTAssertEqual(e.coordinator().tidyOrphanStaging(), 0, "a copy writes in the subfolders, not in the top one")
    }

    func testNothingIsRemovedWhenTheCopyIsRecordedOrItsRecordIsUnreadable() throws {
        let done = try env(self)
        try done.fillWithSoundFile()
        XCTAssertEqual(done.coordinator().files.run().state, .completed)
        try oldStaging(done)
        XCTAssertEqual(done.coordinator().tidyOrphanStaging(), 0)
        XCTAssertEqual(stagings(done.paths.glossaRoot), [".import-staging-OLD"])

        let broken = try env(self)
        try broken.fillWithUnsoundFile()
        try FileManager.default.createDirectory(at: broken.paths.glossaRoot, withIntermediateDirectories: true)
        try Data("not a marker".utf8).write(to: AppSupportMarker.url(in: broken.paths.glossaRoot))
        try oldStaging(broken)
        XCTAssertEqual(broken.coordinator().tidyOrphanStaging(), 0)
        XCTAssertEqual(stagings(broken.paths.glossaRoot), [".import-staging-OLD"])
    }

    func testASandboxedBuildRemovesNothing() throws {
        let e = try env(self)
        try oldStaging(e)
        XCTAssertEqual(e.coordinator(sandboxed: true).tidyOrphanStaging(), 0)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [".import-staging-OLD"])
    }

    func testOnlyOurOwnRealFoldersAreRemoved() throws {
        let e = try env(self)
        let outside = e.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("precious".utf8).write(to: outside.appendingPathComponent("file"))
        try FileManager.default.createDirectory(at: e.paths.glossaRoot, withIntermediateDirectories: true)
        let link = e.paths.glossaRoot.appendingPathComponent(".import-staging-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let plain = e.paths.glossaRoot.appendingPathComponent(".import-staging-file")
        try Data("file".utf8).write(to: plain)
        let other = e.paths.glossaRoot.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("glossa's own".utf8).write(to: other.appendingPathComponent("doc.json"))
        // PageFlow's own folder gets a staging-looking name too: it is not looked at.
        try FileManager.default.createDirectory(at: e.paths.legacyRoot.appendingPathComponent(".import-staging-pf"), withIntermediateDirectories: true)
        let legacyBefore = tree(e.paths.legacyRoot)
        try oldStaging(e)

        XCTAssertEqual(e.coordinator().tidyOrphanStaging(), 1)
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("precious".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertEqual(try Data(contentsOf: other.appendingPathComponent("doc.json")), Data("glossa's own".utf8))
        XCTAssertEqual(tree(e.paths.legacyRoot), legacyBefore)
    }

    func testTidyingCreatesNothingAndDoesNotFailWithoutGlossasFolder() throws {
        let e = try env(self)
        XCTAssertEqual(e.coordinator().tidyOrphanStaging(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path))
    }

    func testEvaluatingAndStatusStillWriteNothing() throws {
        let e = try env(self)
        try oldStaging(e)
        let before = tree(e.base)
        _ = e.coordinator().evaluate()
        _ = e.coordinator().evaluateFiles()
        _ = e.coordinator().files.status()
        XCTAssertEqual(tree(e.base), before)
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Migration/CombinedMigrationCoordinator.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "func evaluateFiles()"))
        let end = try XCTUnwrap(source.range(of: "// MARK: Orphan staging"))
        XCTAssertFalse(source[start.lowerBound..<end.lowerBound].contains("removeOwnStaging"), "deciding what to offer deletes nothing")
        let migrator = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Migration/AppSupportMigrator.swift"), encoding: .utf8)
        let status = try XCTUnwrap(migrator.range(of: "func status()"))
        let run = try XCTUnwrap(migrator.range(of: "func run(confirmLargeAttachments"))
        XCTAssertFalse(migrator[status.lowerBound..<run.lowerBound].contains("removeItem"))
    }

    func testTheLaunchTidiesOffTheMainThreadAndBeforeDeciding() throws {
        let presenter = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Migration/MigrationPresenter.swift"), encoding: .utf8)
        let tidy = try XCTUnwrap(presenter.range(of: "Task.detached(priority: .utility) { coordinator.tidyOrphanStaging() }"))
        let evaluate = try XCTUnwrap(presenter.range(of: "coordinator.evaluate()"))
        XCTAssertLessThan(tidy.lowerBound, evaluate.lowerBound)
    }
}

// MARK: - Swift 6 isolation of the session

final class SessionLifecycleSourceTests: XCTestCase {
    func testTheDeinitTouchesOnlyTheSendableTask() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Migration/MigrationSession.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("deinit { work?.cancel() }"), "a deinit is not isolated: it may only use what is Sendable")
        XCTAssertTrue(source.contains("private var work: Task<Void, Never>?"))
    }

    func testTheExtensionsTheOffersUseAreNotIsolatedToTheMainActor() throws {
        for (file, header) in [("AppSupportMigrator.swift", "nonisolated extension AppSupportInvalidReason"),
                               ("LegacyMigrationCoordinator.swift", "nonisolated extension MigrationOffer.Reason")] {
            let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Migration/" + file), encoding: .utf8)
            XCTAssertTrue(source.contains(header), file)
        }
    }
}

// MARK: - M3: PageFlow's folder is a link

final class LinkedLegacyFolderTests: XCTestCase {
    /// A folder elsewhere with sound files, which the links point to.
    private func target(_ e: Env) throws -> URL {
        let folder = e.base.appendingPathComponent("elsewhere", isDirectory: true)
        for category in ApplicationSupportPaths.Category.allCases {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(category.folderName), withIntermediateDirectories: true)
        }
        let object: [String: Any] = ["path": "/b.epub", "highlights": [], "bookmarks": [], "updatedAt": 1.0, "identifier": NSNull()]
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("EPUB Annotations/x.json"))
        return folder
    }

    private func link(_ url: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    func testALinkedRootGetsItsOwnReasonNotNothingToCopy() throws {
        let e = try env(self)
        let elsewhere = try target(e)
        try link(e.paths.legacyRoot, to: elsewhere)
        let before = tree(elsewhere)

        let prompt = e.coordinator().evaluate()
        XCTAssertEqual(prompt.files, .unavailable(.legacyFolderIsLink))
        XCTAssertNotEqual(prompt.files, .unavailable(.nothingToCopy))
        XCTAssertFalse(prompt.hasOffer, "a link is never followed, so there is nothing to offer")
        XCTAssertTrue(prompt.explanations.contains { $0.hasPrefix("Files:") && $0.contains("link") }, "the menu says why")
        XCTAssertNotEqual(FilesUnavailableReason.legacyFolderIsLink.explanation, FilesUnavailableReason.nothingToCopy.explanation)
        XCTAssertEqual(tree(elsewhere), before, "what it points to is untouched")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: e.paths.legacyRoot.path))
    }

    func testADanglingLinkIsTheSame() throws {
        let e = try env(self)
        try link(e.paths.legacyRoot, to: e.base.appendingPathComponent("gone"))
        XCTAssertEqual(e.coordinator().evaluate().files, .unavailable(.legacyFolderIsLink))
    }

    func testLinkedCategoryFoldersAreReportedToo() throws {
        let e = try env(self)
        let elsewhere = try target(e)
        for category in ApplicationSupportPaths.Category.allCases {
            try link(e.paths.legacyDirectory(for: category), to: elsewhere.appendingPathComponent(category.folderName))
        }
        XCTAssertEqual(e.coordinator().evaluate().files, .unavailable(.legacyFolderIsLink))
    }

    func testOneLinkedFolderDoesNotHideTheOthers() throws {
        let e = try env(self)
        let elsewhere = try target(e)
        try link(e.paths.legacyDirectory(for: .epubAnnotations), to: elsewhere.appendingPathComponent("EPUB Annotations"))
        try e.put(Data("{}".utf8), "r.json", .recovery)
        let offer = try XCTUnwrap(e.coordinator().evaluate().files.offer)
        XCTAssertEqual(offer.lines.map(\.category), [.recovery], "only the real folder is offered, the link is not followed")
    }

    func testRealEmptyOrMissingFoldersStillSayNothingToCopy() throws {
        let e = try env(self)
        XCTAssertEqual(e.coordinator().evaluate().files, .unavailable(.nothingToCopy), "no folder at all")
        try FileManager.default.createDirectory(at: e.paths.legacyDirectory(for: .recovery), withIntermediateDirectories: true)
        XCTAssertEqual(e.coordinator().evaluate().files, .unavailable(.nothingToCopy), "an empty real folder")
    }

    func testASandboxedBuildStillSaysSandboxedBeforeLookingAtLinks() throws {
        let e = try env(self)
        try link(e.paths.legacyRoot, to: try target(e))
        XCTAssertEqual(e.coordinator(sandboxed: true).evaluate().files, .unavailable(.sandboxed))
    }

    func testRunningWithALinkedRootCopiesNothingAndCreatesNothing() throws {
        let e = try env(self)
        let elsewhere = try target(e)
        try link(e.paths.legacyRoot, to: elsewhere)
        let before = tree(elsewhere)
        let report = e.coordinator().files.run()
        XCTAssertEqual(report.state, .nothingToCopy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path))
        XCTAssertEqual(tree(elsewhere), before)
    }
}

// MARK: - Folders that cannot be read

/// Fails the listing of the folders whose path ends with one of the given names, as a permission error would.
private final class FailingListing: FileManager, @unchecked Sendable {
    let failing: [String]
    init(failing: [String]) { self.failing = failing; super.init() }
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if failing.contains(where: { path.hasSuffix("/" + $0) }) {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        return try super.contentsOfDirectory(atPath: path)
    }
}

final class UnreadableLegacyFolderTests: XCTestCase {
    private func coordinator(_ e: Env, failing: [String]) -> CombinedMigrationCoordinator {
        var c = e.coordinator()
        c.files.fileManager = FailingListing(failing: failing)
        return c
    }

    private func makeFolders(_ e: Env, files: [ApplicationSupportPaths.Category] = []) throws {
        for category in ApplicationSupportPaths.Category.allCases {
            try FileManager.default.createDirectory(at: e.paths.legacyDirectory(for: category), withIntermediateDirectories: true)
        }
        for category in files {
            try Data("{}".utf8).write(to: e.paths.legacyDirectory(for: category).appendingPathComponent("x.json"))
        }
    }

    func testAFailedListingIsNotNothingToCopy() throws {
        let e = try env(self)
        try makeFolders(e)
        let prompt = coordinator(e, failing: ["Recovery"]).evaluate()
        XCTAssertEqual(prompt.files, .unavailable(.legacyFolderUnreadable))
        XCTAssertFalse(prompt.hasOffer)
        XCTAssertTrue(prompt.explanations.contains { $0.hasPrefix("Files:") && $0.contains("could not read") })
        XCTAssertNotEqual(FilesUnavailableReason.legacyFolderUnreadable.explanation, FilesUnavailableReason.nothingToCopy.explanation)
        XCTAssertNotEqual(FilesUnavailableReason.legacyFolderUnreadable.explanation, FilesUnavailableReason.legacyFolderIsLink.explanation)
        XCTAssertEqual(coordinator(e, failing: []).evaluate().files, .unavailable(.nothingToCopy), "the same folders, readable: nothing there")
    }

    func testOneUnreadableFolderIsReportedInTheOfferForTheOthers() throws {
        let e = try env(self)
        try makeFolders(e, files: [.epubAnnotations])
        let offer = try XCTUnwrap(coordinator(e, failing: ["Recovery"]).evaluate().files.offer)
        XCTAssertEqual(offer.lines.map(\.category), [.epubAnnotations])
        XCTAssertEqual(offer.unreadable, [.recovery], "the window says what will not be copied")
        XCTAssertEqual(try XCTUnwrap(coordinator(e, failing: []).evaluate().files.offer).unreadable, [])
        let view = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Views/MigrationView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("offer.unreadable"))
        XCTAssertTrue(view.contains("could not read"))
    }

    func testEveryCategoryCanBeTheUnreadableOne() throws {
        for category in ApplicationSupportPaths.Category.allCases {
            let e = try env(self)
            try makeFolders(e)
            let candidates = AppSupportCandidates(paths: e.paths, fileManager: FailingListing(failing: [category.folderName]))
            XCTAssertEqual(candidates.unreadableFolders(), [category])
        }
    }

    func testMissingEmptyAndLinkedFoldersAreNotUnreadable() throws {
        let e = try env(self)
        XCTAssertEqual(AppSupportCandidates(paths: e.paths).unreadableFolders(), [], "no folder at all")
        try makeFolders(e)
        XCTAssertEqual(AppSupportCandidates(paths: e.paths).unreadableFolders(), [], "empty folders")
        let link = try env(self)
        try FileManager.default.createDirectory(at: link.paths.legacyRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.paths.legacyRoot, withDestinationURL: link.base.appendingPathComponent("elsewhere"))
        XCTAssertEqual(AppSupportCandidates(paths: link.paths).unreadableFolders(), [], "a link is its own case")
        XCTAssertEqual(link.coordinator().evaluate().files, .unavailable(.legacyFolderIsLink))
    }

    func testARealPermissionErrorOnAFolderIsDetected() throws {
        let e = try env(self)
        try makeFolders(e)
        let folder = e.paths.legacyDirectory(for: .attachments)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil else { throw XCTSkip("running with rights that ignore permissions") }
        XCTAssertEqual(AppSupportCandidates(paths: e.paths).unreadableFolders(), [.attachments])
        XCTAssertEqual(e.coordinator().evaluate().files, .unavailable(.legacyFolderUnreadable))
    }

    func testAnUnreadableRootMakesAllThreeUnreadable() throws {
        let e = try env(self)
        try makeFolders(e)
        let root = e.paths.legacyRoot
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) == nil else { throw XCTSkip("running with rights that ignore permissions") }
        XCTAssertEqual(AppSupportCandidates(paths: e.paths).unreadableFolders(), ApplicationSupportPaths.Category.allCases)
        XCTAssertEqual(e.coordinator().evaluate().files, .unavailable(.legacyFolderUnreadable))
    }

    func testLookingAtItWritesNothingAndASandboxedBuildStillSaysSandboxed() throws {
        let e = try env(self)
        try makeFolders(e)
        let before = tree(e.base)
        _ = coordinator(e, failing: ["Recovery"]).evaluate()
        XCTAssertEqual(tree(e.base), before)
        var sandboxed = e.coordinator(sandboxed: true)
        sandboxed.files.fileManager = FailingListing(failing: ["Recovery"])
        XCTAssertEqual(sandboxed.evaluate().files, .unavailable(.sandboxed))
    }

    func testAnOldStagingWithNoOfferBecauseOfUnreadableFoldersIsStillTidied() throws {
        let e = try env(self)
        try makeFolders(e)
        try e.leaveStaging()
        let old = e.paths.glossaRoot.appendingPathComponent(".import-staging-OLD")
        for item in [old, old.appendingPathComponent("Recovery")] {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-5 * 3600)], ofItemAtPath: item.path)
        }
        XCTAssertEqual(coordinator(e, failing: ["Recovery"]).tidyOrphanStaging(), 1)
    }

    func testTheCopyEngineIsUnchangedByThisDistinction() throws {
        let e = try env(self)
        try makeFolders(e, files: [])
        try e.fillWithSoundFile()
        // The engine still copies what it can read and records its marker as before; the warning is the offer's.
        XCTAssertEqual(e.coordinator().files.run().state, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AppSupportMarker.url(in: e.paths.glossaRoot).path))
    }
}

// MARK: - A category that cannot be read is not a finished copy

private struct PartialRecoveryRecord: Codable {
    var id: UUID
    var title: String
    var originalURL: URL?
    var source: String
    var commentBlock: String?
    var updatedAt: Date
}

@MainActor final class PartialCopyTests: XCTestCase {
    /// PageFlow with one sound recovery file and one sound EPUB annotation file. Returns the recovery file's name.
    @discardableResult
    private func fill(_ e: Env) throws -> String {
        let id = UUID()
        let record = PartialRecoveryRecord(id: id, title: "T", originalURL: nil, source: "# T", commentBlock: nil,
                                           updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try e.put(try JSONEncoder().encode(record), id.uuidString + ".json", .recovery)
        try e.fillWithSoundFile()
        return id.uuidString + ".json"
    }

    private func migrator(_ e: Env, failing: [String]) -> AppSupportMigrator {
        var m = e.coordinator().files
        m.fileManager = failing.isEmpty ? .default : FailingListing(failing: failing)
        return m
    }

    private func marker(_ e: Env) -> Bool { FileManager.default.fileExists(atPath: AppSupportMarker.url(in: e.paths.glossaRoot).path) }

    func testWhatCanBeReadIsCopiedButNothingIsRecordedAsDone() throws {
        let e = try env(self)
        let recoveryName = try fill(e)
        let legacyBefore = tree(e.paths.legacyRoot)

        let report = migrator(e, failing: ["Recovery"]).run()
        XCTAssertEqual(report.state, .partial(unreadable: [.recovery]))
        XCTAssertEqual(report.copied.map(\.category), [.epubAnnotations], "the readable category was copied")
        XCTAssertEqual(names(e.paths.directory(for: .epubAnnotations)).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.directory(for: .recovery).appendingPathComponent(recoveryName).path))
        XCTAssertFalse(marker(e), "no marker: the copy is not complete")
        XCTAssertEqual(stagings(e.paths.glossaRoot), [], "our staging is removed")
        XCTAssertEqual(tree(e.paths.legacyRoot), legacyBefore, "PageFlow is untouched")
        XCTAssertEqual(migrator(e, failing: ["Recovery"]).status(), .notStarted)
    }

    func testAfterReopeningTheCopyIsOfferedAgainAndNotReportedAsCopied() throws {
        let e = try env(self)
        try fill(e)
        _ = migrator(e, failing: ["Recovery"]).run()

        var stillBroken = e.coordinator()
        stillBroken.files.fileManager = FailingListing(failing: ["Recovery"])
        let offer = try XCTUnwrap(stillBroken.evaluateFiles().offer, "still offered, not 'already copied'")
        XCTAssertEqual(offer.unreadable, [.recovery])
        XCTAssertFalse(offer.interrupted, "nothing was cut off")

        let healthy = e.coordinator()
        XCTAssertNotNil(healthy.evaluateFiles().offer)
        XCTAssertNotEqual(healthy.evaluateFiles(), .unavailable(.alreadyCopied))
    }

    func testOnceTheFolderCanBeReadTheRestIsCopiedAndTheFirstCategoryIsOnlyRecognised() throws {
        let e = try env(self)
        let recoveryName = try fill(e)
        let first = migrator(e, failing: ["Recovery"]).run()
        let epubFile = try XCTUnwrap(names(e.paths.directory(for: .epubAnnotations)).first)
        let epubURL = e.paths.directory(for: .epubAnnotations).appendingPathComponent(epubFile)
        let epubBefore = try Data(contentsOf: epubURL)
        let epubDate = try epubURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        XCTAssertEqual(first.state, .partial(unreadable: [.recovery]))

        let second = migrator(e, failing: []).run()
        XCTAssertEqual(second.state, .completed)
        XCTAssertEqual(second.copied.map(\.category), [.recovery], "only what was missing is copied")
        XCTAssertEqual(second.identical.map(\.category), [.epubAnnotations], "what was copied before is recognised, not copied again")
        XCTAssertEqual(try Data(contentsOf: epubURL), epubBefore)
        XCTAssertEqual(try epubURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, epubDate, "and left alone")
        XCTAssertEqual(names(e.paths.directory(for: .epubAnnotations)).count, 1, "no duplicates")
        XCTAssertEqual(names(e.paths.directory(for: .recovery)), [recoveryName])
        XCTAssertTrue(marker(e))
        let record = try JSONDecoder().decode(AppSupportMarker.self, from: Data(contentsOf: AppSupportMarker.url(in: e.paths.glossaRoot)))
        XCTAssertEqual(record.files.map(\.category).sorted(), ["epubAnnotations", "recovery"], "the marker accounts for both")
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
        XCTAssertEqual(e.coordinator().evaluateFiles(), .unavailable(.alreadyCopied), "and now it is done")
        XCTAssertEqual(migrator(e, failing: []).run().state, .alreadyCompleted)
    }

    func testRepeatedPartialRunsChangeNothingAndKeepOffering() throws {
        let e = try env(self)
        try fill(e)
        _ = migrator(e, failing: ["Recovery"]).run()
        let afterFirst = tree(e.paths.glossaRoot)
        for _ in 0..<3 {
            let report = migrator(e, failing: ["Recovery"]).run()
            XCTAssertEqual(report.state, .partial(unreadable: [.recovery]))
            XCTAssertEqual(report.identical.count, 1)
            XCTAssertTrue(report.copied.isEmpty)
        }
        XCTAssertEqual(tree(e.paths.glossaRoot), afterFirst)
        XCTAssertFalse(marker(e))
    }

    func testEveryCategoryUnreadableCopiesNothingAndRecordsNothing() throws {
        let e = try env(self)
        try fill(e)
        let report = migrator(e, failing: ["Recovery", "EPUB Annotations"]).run()
        XCTAssertEqual(report.state, .partial(unreadable: [.recovery, .epubAnnotations]))
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertFalse(marker(e))
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path), "nothing was written at all")
        XCTAssertEqual(migrator(e, failing: []).run().state, .completed, "and the next, readable run does it all")
    }

    func testGlossasOwnFileStillWinsAcrossThePartialAndTheCompletingRun() throws {
        let e = try env(self)
        let name = try fill(e)
        try FileManager.default.createDirectory(at: e.paths.directory(for: .recovery), withIntermediateDirectories: true)
        try Data("Glossa's own".utf8).write(to: e.paths.directory(for: .recovery).appendingPathComponent(name))
        _ = migrator(e, failing: ["EPUB Annotations"]).run()
        let completed = migrator(e, failing: []).run()
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.conflicts.map(\.name), [name])
        XCTAssertEqual(try Data(contentsOf: e.paths.directory(for: .recovery).appendingPathComponent(name)), Data("Glossa's own".utf8))
    }

    func testARealPermissionErrorThenRestoredPermissions() throws {
        let e = try env(self)
        try fill(e)
        let folder = e.paths.legacyDirectory(for: .recovery)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        guard (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) == nil else { throw XCTSkip("rights that ignore permissions") }

        let partial = e.coordinator().files.run()
        XCTAssertEqual(partial.state, .partial(unreadable: [.recovery]))
        XCTAssertFalse(marker(e))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertEqual(e.coordinator().files.run().state, .completed)
        XCTAssertTrue(marker(e))
    }

    func testTheWindowSaysItAndTheCopyIsOfferedInTheNextSession() throws {
        let e = try env(self)
        try fill(e)
        var broken = e.coordinator()
        broken.files.fileManager = FailingListing(failing: ["Recovery"])
        let closed = ClosedCalls()
        let session = MigrationSession(prompt: broken.evaluate(), coordinator: broken, defersWork: false) { closed.calls.append($0) }
        session.choose(.importNow)
        guard case .finished(let result) = session.phase, let files = result.files else { return XCTFail("\(session.phase)") }
        XCTAssertFalse(files.completed)
        XCTAssertTrue(files.problem?.contains("could not read Recovery") == true)
        XCTAssertTrue(files.problem?.contains("offered again") == true)
        XCTAssertEqual(files.copiedFiles, 1)
        XCTAssertFalse(marker(e))

        // A later launch, permissions fixed: offered again, and it completes.
        let healthy = e.coordinator()
        let again = MigrationSession(prompt: healthy.evaluate(), coordinator: healthy, defersWork: false) { closed.calls.append($0) }
        XCTAssertNotNil(again.prompt.files.offer)
        again.choose(.importNow)
        guard case .finished(let second) = again.phase else { return XCTFail("\(again.phase)") }
        XCTAssertEqual(second.files?.completed, true)
        XCTAssertEqual(second.files?.identical, 1)
        XCTAssertTrue(marker(e))
    }

    func testTheDocumentsSayItAndTheOfferTextMatches() throws {
        let doc = try String(contentsOf: repositoryRoot().appendingPathComponent("docs/GLOSSA-IDENTITY-SEPARATION.md"), encoding: .utf8)
        XCTAssertTrue(doc.contains("non si scrive il marker"))
        XCTAssertTrue(doc.contains("nulla era illeggibile"))
        let readme = try String(contentsOf: repositoryRoot().appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("does **not** record the copy as done"))
        let view = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Views/MigrationView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("the copy is not recorded as done"))
    }

    private final class ClosedCalls { var calls: [Bool] = [] }
}

// MARK: - Unreadable files, and files that can never be copied

@MainActor final class UnreadableFileAndInvalidOnlyTests: XCTestCase {
    private func recoveryRecord(_ e: Env) throws -> String {
        let id = UUID()
        let record = PartialRecoveryRecord(id: id, title: "T", originalURL: nil, source: "# T", commentBlock: nil,
                                           updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try e.put(try JSONEncoder().encode(record), id.uuidString + ".json", .recovery)
        return id.uuidString + ".json"
    }

    private func marker(_ e: Env) -> Bool { FileManager.default.fileExists(atPath: AppSupportMarker.url(in: e.paths.glossaRoot).path) }

    /// Makes `url` unreadable, restored at the end of the test. Skips where permissions are not enforced.
    private func lock(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        guard (try? Data(contentsOf: url)) == nil else { throw XCTSkip("rights that ignore permissions") }
    }

    // M-A

    func testAFileWithNoPermissionsMakesItsCategoryPartialAndTheRestIsCopied() throws {
        let e = try env(self)
        let name = try recoveryRecord(e)
        try e.fillWithSoundFile()
        let file = e.paths.legacyDirectory(for: .recovery).appendingPathComponent(name)
        try lock(file)
        let legacyNames = names(e.paths.legacyDirectory(for: .recovery))

        let report = e.coordinator().files.run()
        XCTAssertEqual(report.state, .partial(unreadable: [.recovery]))
        XCTAssertEqual(report.copied.map(\.category), [.epubAnnotations], "the readable category was copied")
        XCTAssertFalse(marker(e), "no marker: an unreadable file is not a finished copy")
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
        XCTAssertEqual(names(e.paths.legacyDirectory(for: .recovery)), legacyNames, "PageFlow is untouched")
        XCTAssertNotNil(e.coordinator().evaluateFiles().offer, "and it is offered again")
    }

    func testRestoringThePermissionCompletesItWithoutCopyingTheRestTwice() throws {
        let e = try env(self)
        let name = try recoveryRecord(e)
        try e.fillWithSoundFile()
        let file = e.paths.legacyDirectory(for: .recovery).appendingPathComponent(name)
        try lock(file)
        XCTAssertEqual(e.coordinator().files.run().state, .partial(unreadable: [.recovery]))
        let epubName = try XCTUnwrap(names(e.paths.directory(for: .epubAnnotations)).first)
        let epubURL = e.paths.directory(for: .epubAnnotations).appendingPathComponent(epubName)
        let epubDate = try epubURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let second = e.coordinator().files.run()
        XCTAssertEqual(second.state, .completed)
        XCTAssertEqual(second.copied.map(\.category), [.recovery])
        XCTAssertEqual(second.identical.map(\.category), [.epubAnnotations], "what was copied before is only recognised")
        XCTAssertEqual(try epubURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, epubDate)
        XCTAssertEqual(names(e.paths.directory(for: .epubAnnotations)).count, 1)
        XCTAssertEqual(names(e.paths.directory(for: .recovery)), [name])
        XCTAssertTrue(marker(e))
        XCTAssertEqual(e.coordinator().evaluateFiles(), .unavailable(.alreadyCopied))
    }

    func testAnUnreadableFileAmongInvalidOnesIsStillPartial() throws {
        let e = try env(self)
        let name = try recoveryRecord(e)
        try e.put(Data("{".utf8), UUID().uuidString + ".json", .attachments)       // permanently invalid
        let file = e.paths.legacyDirectory(for: .recovery).appendingPathComponent(name)
        try lock(file)
        let report = e.coordinator().files.run()
        XCTAssertEqual(report.state, .partial(unreadable: [.recovery]), "nothing sound to copy, but not finished either")
        XCTAssertFalse(marker(e))
    }

    func testAnUnreadableFileIsNotListedAsInvalidInAMarker() throws {
        let e = try env(self)
        let name = try recoveryRecord(e)
        try e.fillWithSoundFile()
        let file = e.paths.legacyDirectory(for: .recovery).appendingPathComponent(name)
        try lock(file)
        _ = e.coordinator().files.run()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        _ = e.coordinator().files.run()
        let record = try JSONDecoder().decode(AppSupportMarker.self, from: Data(contentsOf: AppSupportMarker.url(in: e.paths.glossaRoot)))
        XCTAssertEqual(record.invalid.count, 0, "it was read the second time, so it is not in the skipped list")
    }

    // M-B

    func testOnlyPermanentlyInvalidFilesConcludeTheMigrationAndAreRecorded() throws {
        let e = try env(self)
        let bad = UUID().uuidString + ".json"
        try e.put(Data("{".utf8), bad, .recovery)
        try e.put(Data("not an image".utf8), "x.png", .attachments)
        let legacyBefore = tree(e.paths.legacyRoot)

        let report = e.coordinator().files.run()
        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(report.invalid.count, 2)
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertTrue(marker(e))
        let record = try JSONDecoder().decode(AppSupportMarker.self, from: Data(contentsOf: AppSupportMarker.url(in: e.paths.glossaRoot)))
        XCTAssertEqual(record.invalid.map(\.name).sorted(), [bad, "x.png"].sorted())
        XCTAssertEqual(record.files.count, 0)
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
        XCTAssertEqual(tree(e.paths.legacyRoot), legacyBefore, "PageFlow is untouched")
        XCTAssertEqual(names(e.paths.directory(for: .recovery)), [], "nothing copied")
    }

    func testTwoLaunchesWithOnlyInvalidFilesTheSecondOffersNothing() throws {
        let e = try env(self)
        try e.put(Data("{".utf8), UUID().uuidString + ".json", .recovery)
        // First launch: offered, and the reader imports.
        let firstLaunch = e.coordinator()
        XCTAssertNotNil(firstLaunch.evaluateFiles().offer)
        let session = MigrationSession(prompt: firstLaunch.evaluate(), coordinator: firstLaunch, defersWork: false) { _ in }
        session.choose(.importNow)
        guard case .finished(let result) = session.phase, let files = result.files else { return XCTFail("\(session.phase)") }
        XCTAssertTrue(files.completed)
        XCTAssertEqual(files.invalid, 1)
        XCTAssertNil(files.problem, "not shown as an error: it is concluded")
        XCTAssertTrue(marker(e))
        // Second launch: nothing to offer, and no window.
        let secondLaunch = e.coordinator()
        XCTAssertEqual(secondLaunch.evaluateFiles(), .unavailable(.alreadyCopied))
        XCTAssertFalse(secondLaunch.evaluate().files.offer != nil)
        XCTAssertEqual(secondLaunch.files.run().state, .alreadyCompleted)
    }

    func testTheWindowSaysNothingWasSoundEnoughToCopy() throws {
        let view = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Views/MigrationView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("Nothing was sound enough to copy"))
        XCTAssertTrue(view.contains("summary.copiedFiles + summary.identical > 0 ? \"Files copied\" : \"Files\""))
    }

    func testNoFilesAtAllRecordsNothing() throws {
        let e = try env(self)
        try FileManager.default.createDirectory(at: e.paths.legacyDirectory(for: .recovery), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: e.paths.legacyDirectory(for: .attachments), withIntermediateDirectories: true)
        XCTAssertEqual(e.coordinator().files.run().state, .nothingToCopy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path))
        XCTAssertEqual(e.coordinator().evaluateFiles(), .unavailable(.nothingToCopy))
        // Hidden files, links and subfolders are not files either.
        try Data("x".utf8).write(to: e.paths.legacyDirectory(for: .recovery).appendingPathComponent(".hidden"))
        try FileManager.default.createDirectory(at: e.paths.legacyDirectory(for: .recovery).appendingPathComponent("sub"), withIntermediateDirectories: true)
        XCTAssertEqual(e.coordinator().files.run().state, .nothingToCopy)
        XCTAssertFalse(marker(e))
    }

    // The three situations side by side.

    func testTheThreeSituationsAreTold() throws {
        // (a) something cannot be read: not concluded, tried again.
        let a = try env(self)
        let name = try recoveryRecord(a)
        try lock(a.paths.legacyDirectory(for: .recovery).appendingPathComponent(name))
        XCTAssertEqual(a.coordinator().files.run().state, .partial(unreadable: [.recovery]))
        XCTAssertFalse(marker(a))
        XCTAssertNotNil(a.coordinator().evaluateFiles().offer)
        // (b) files, all permanently invalid: concluded and recorded.
        let b = try env(self)
        try b.put(Data("{".utf8), UUID().uuidString + ".json", .recovery)
        XCTAssertEqual(b.coordinator().files.run().state, .completed)
        XCTAssertTrue(marker(b))
        XCTAssertNil(b.coordinator().evaluateFiles().offer)
        // (c) no file: nothing recorded, nothing offered.
        let c = try env(self)
        try FileManager.default.createDirectory(at: c.paths.legacyDirectory(for: .recovery), withIntermediateDirectories: true)
        XCTAssertEqual(c.coordinator().files.run().state, .nothingToCopy)
        XCTAssertFalse(marker(c))
        XCTAssertNil(c.coordinator().evaluateFiles().offer)
    }

    func testTheDocumentsTellTheThreeSituations() throws {
        let doc = try String(contentsOf: repositoryRoot().appendingPathComponent("docs/GLOSSA-IDENTITY-SEPARATION.md"), encoding: .utf8)
        for text in ["né una cartella né un singolo file", "(a)", "(b)", "(c)", "definitivamente non validi"] {
            XCTAssertTrue(doc.contains(text), text)
        }
        let readme = try String(contentsOf: repositoryRoot().appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("none is sound"))
        XCTAssertTrue(readme.contains("a single file in it, cannot be read"))
    }
}

// MARK: - Retries do not copy again what Glossa already has

/// Counts the copies made, and can change a file of PageFlow's once the scan of its last category begins.
private final class RetryFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var copies: [String] = []
    var afterScanOfRecovery: (() -> Void)?
    private var epubListings = 0
    var copyCount: Int { lock.lock(); defer { lock.unlock() }; return copies.count }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        lock.lock(); copies.append(srcURL.lastPathComponent); lock.unlock()
        try super.copyItem(at: srcURL, to: dstURL)
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        let result = try super.contentsOfDirectory(atPath: path)
        if path.hasSuffix("/EPUB Annotations"), path.contains("/PageFlow/") {
            lock.lock(); epubListings += 1; let n = epubListings; lock.unlock()
            if n == 3 { afterScanOfRecovery?() }      // the count, the check that it can be read, then the scan
        }
        return result
    }
}

final class RetryWithoutRecopyTests: XCTestCase {
    private func bigRecovery(_ e: Env, megabytes: Int = 3) throws -> String {
        let id = UUID()
        let record = PartialRecoveryRecord(id: id, title: "T", originalURL: nil,
                                           source: String(repeating: "a", count: megabytes * 1_000_000),
                                           commentBlock: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try e.put(try JSONEncoder().encode(record), id.uuidString + ".json", .recovery)
        return id.uuidString + ".json"
    }

    private func smallRecovery(_ e: Env) throws -> String {
        let id = UUID()
        let record = PartialRecoveryRecord(id: id, title: "T", originalURL: nil, source: "# T", commentBlock: nil,
                                           updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try e.put(try JSONEncoder().encode(record), id.uuidString + ".json", .recovery)
        return id.uuidString + ".json"
    }

    private func migrator(_ e: Env, _ fm: FileManager, space: Int64? = Int64.max / 4, staged: Counter? = nil) -> AppSupportMigrator {
        var m = e.coordinator().files
        m.fileManager = fm
        m.availableSpace = { _ in space }
        if let staged { m.checkpoint = { if case .staged(_, let name) = $0 { staged.add(name) } } }
        return m
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var names: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func marker(_ e: Env) -> URL { AppSupportMarker.url(in: e.paths.glossaRoot) }

    func testARetryCopiesOnlyWhatIsMissing() throws {
        let e = try env(self)
        let recoveryName = try smallRecovery(e)
        try e.fillWithSoundFile()
        // First run: the EPUB folder cannot be read, so only the recovery file is copied and nothing is recorded.
        XCTAssertEqual(migrator(e, FailingListing(failing: ["EPUB Annotations"])).run().state, .partial(unreadable: [.epubAnnotations]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(e).path))
        let recoveryURL = e.paths.directory(for: .recovery).appendingPathComponent(recoveryName)
        let before = try recoveryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let counting = RetryFileManager()
        let staged = Counter()
        let report = migrator(e, counting, staged: staged).run()
        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(counting.copies.count, 1, "one copy: the file that was missing")
        XCTAssertEqual(staged.names.count, 1)
        XCTAssertFalse(staged.names.contains(recoveryName), "the one already in Glossa is not staged again")
        XCTAssertEqual(report.copied.map(\.category), [.epubAnnotations])
        XCTAssertEqual(report.identical.map(\.name), [recoveryName], "it is recognised, and in the report")
        XCTAssertEqual(try recoveryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before)
        let record = try JSONDecoder().decode(AppSupportMarker.self, from: Data(contentsOf: marker(e)))
        XCTAssertEqual(record.files.map(\.outcome).sorted(), ["copied", "identical"])
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
    }

    func testWhenEverythingIsAlreadyThereNothingIsCopiedAtAll() throws {
        let e = try env(self)
        _ = try smallRecovery(e)
        try e.fillWithSoundFile()
        XCTAssertEqual(migrator(e, .default).run().state, .completed)
        try FileManager.default.removeItem(at: marker(e))             // as if the record had never been written
        let glossaBefore = tree(e.paths.glossaRoot)

        let counting = RetryFileManager()
        let report = migrator(e, counting).run()
        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(counting.copyCount, 0)
        XCTAssertEqual(report.identical.count, 2)
        XCTAssertTrue(report.copied.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker(e).path), "recorded, now that it is accounted for")
        let after = tree(e.paths.glossaRoot).filter { !$0.contains(".migration-appsupport") }
        XCTAssertEqual(after, glossaBefore.filter { !$0.contains(".migration-appsupport") }, "Glossa's files are as they were")
    }

    func testAFileThatDiffersIsAConflictWithoutBeingCopiedAndGlossaWins() throws {
        let e = try env(self)
        let name = try smallRecovery(e)
        try e.fillWithSoundFile()
        try FileManager.default.createDirectory(at: e.paths.directory(for: .recovery), withIntermediateDirectories: true)
        try Data("Glossa's own".utf8).write(to: e.paths.directory(for: .recovery).appendingPathComponent(name))
        let legacyBefore = tree(e.paths.legacyRoot)

        let counting = RetryFileManager()
        let staged = Counter()
        let report = migrator(e, counting, staged: staged).run()
        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(report.conflicts.map(\.name), [name])
        XCTAssertFalse(staged.names.contains(name), "a conflict is settled without copying")
        XCTAssertEqual(counting.copyCount, 1, "only the EPUB file")
        XCTAssertEqual(try Data(contentsOf: e.paths.directory(for: .recovery).appendingPathComponent(name)), Data("Glossa's own".utf8))
        XCTAssertEqual(tree(e.paths.legacyRoot), legacyBefore)
        let record = try JSONDecoder().decode(AppSupportMarker.self, from: Data(contentsOf: marker(e)))
        XCTAssertEqual(record.files.first { $0.name == name }?.outcome, "conflict")
    }

    func testSomethingThatIsNotAFileAtTheNameIsStillAConflict() throws {
        let e = try env(self)
        let name = try smallRecovery(e)
        try FileManager.default.createDirectory(at: e.paths.directory(for: .recovery).appendingPathComponent(name), withIntermediateDirectories: true)
        let counting = RetryFileManager()
        let report = migrator(e, counting).run()
        XCTAssertEqual(report.conflicts.map(\.name), [name])
        XCTAssertEqual(counting.copyCount, 0)
    }

    func testAFileOfPageFlowThatChangedSinceTheScanGoesTheNormalWayAndIsCaught() throws {
        let e = try env(self)
        let name = try smallRecovery(e)
        try e.fillWithSoundFile()
        XCTAssertEqual(migrator(e, .default).run().state, .completed)
        try FileManager.default.removeItem(at: marker(e))
        let glossaFile = e.paths.directory(for: .recovery).appendingPathComponent(name)
        let glossaBytes = try Data(contentsOf: glossaFile)

        let counting = RetryFileManager()
        let legacyFile = e.paths.legacyDirectory(for: .recovery).appendingPathComponent(name)
        counting.afterScanOfRecovery = { try? Data("{\"changed\": true}".utf8).write(to: legacyFile) }      // after the scan hashed it
        let report = migrator(e, counting).run()
        XCTAssertEqual(report.state, .incomplete, "not trusted as identical: it was staged, and the change was caught")
        XCTAssertEqual(report.failures.map(\.name), [name])
        XCTAssertEqual(try Data(contentsOf: glossaFile), glossaBytes, "Glossa's file is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker(e).path))
        XCTAssertEqual(stagings(e.paths.glossaRoot), [])
    }

    func testRoomIsNeededOnlyForWhatIsLeftToCopy() throws {
        let tight: Int64 = 1_048_576 + 100_000         // the margin, and a little: not enough for a 3 MB file
        // A first, partial run copied the big file; the retry needs room for the small one only.
        let e = try env(self)
        _ = try bigRecovery(e)
        try e.fillWithSoundFile()
        XCTAssertEqual(migrator(e, FailingListing(failing: ["EPUB Annotations"])).run().state, .partial(unreadable: [.epubAnnotations]))
        let counting = RetryFileManager()
        let retry = migrator(e, counting, space: tight).run()
        XCTAssertEqual(retry.state, .completed, "enough for the missing file")
        XCTAssertEqual(counting.copyCount, 1)

        // The same space, with nothing copied before: not enough, and nothing is written.
        let fresh = try env(self)
        _ = try bigRecovery(fresh)
        try fresh.fillWithSoundFile()
        let refused = migrator(fresh, .default, space: tight).run()
        guard case .insufficientSpace = refused.state else { return XCTFail("\(refused.state)") }
        XCTAssertTrue(refused.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.paths.glossaRoot.path))
    }

    func testNoRoomIsNeededWhenNothingIsLeftToCopy() throws {
        let e = try env(self)
        _ = try smallRecovery(e)
        try e.fillWithSoundFile()
        XCTAssertEqual(migrator(e, .default).run().state, .completed)
        try FileManager.default.removeItem(at: marker(e))
        XCTAssertEqual(migrator(e, .default, space: 0).run().state, .completed)
        XCTAssertEqual(migrator(e, .default, space: nil).run().state, .alreadyCompleted, "and with the record there, nothing is looked at")
    }

    func testTheConfirmationThresholdIsUnchanged() throws {
        let e = try env(self)
        try e.put(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!, "p.png", .attachments)
        XCTAssertEqual(migrator(e, .default).run().state, .completed)
        try FileManager.default.removeItem(at: marker(e))
        var asking = migrator(e, .default)
        asking.largeAttachmentsThreshold = 1
        if case .needsConfirmation = asking.run().state {} else { XCTFail("the question is asked as before, even for attachments already copied") }
        XCTAssertEqual(AppSupportMigrator.defaultLargeAttachmentsThreshold, 500 * 1_048_576)
    }

    func testTheCodeKeepsItsChecks() throws {
        let code = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Migration/AppSupportMigrator.swift"), encoding: .utf8)
        XCTAssertTrue(code.contains("sourceIsAsScanned(file)"))
        XCTAssertTrue(code.contains("if !toCopy.isEmpty {"), "the room is checked for what is left to copy")
        XCTAssertTrue(code.contains("for file in toCopy {"), "and only that is staged")
        XCTAssertTrue(code.contains("guard let copied = Self.sha256(of: target), copied == file.sha256"), "the copy is still verified")
        XCTAssertTrue(code.contains("the source changed while it was copied"))
        XCTAssertTrue(code.contains("moveItem(at: staged, to: target)"), "and the merge still never replaces")
    }
}

// MARK: - The result's heading tells the truth

@MainActor final class ResultTitleTests: XCTestCase {
    private func result(of e: Env, failing: [String] = [], threshold: Int64? = nil, cancel: Bool = false) throws -> MigrationSession.MigrationResult {
        var flow = e.coordinator()
        if !failing.isEmpty { flow.files.fileManager = FailingListing(failing: failing) }
        let session = MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: false) { _ in }
        session.choose(.importNow)
        if case .confirmingLargeAttachments = session.phase { session.confirmLargeAttachments(false) }
        guard case .finished(let result) = session.phase else { throw XCTSkip("\(session.phase)") }
        return result
    }

    func testACompleteImportIsFinished() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        let r = try result(of: e)
        XCTAssertTrue(r.isComplete)
        XCTAssertEqual(r.title, "Import finished")
    }

    func testOnlyInvalidFilesStillConcludeAndAreFinished() throws {
        let e = try env(self)
        try e.fillWithUnsoundFile()
        XCTAssertEqual(try result(of: e).title, "Import finished", "recorded as done: nothing more to wait for")
    }

    func testAPartialCopyIsNotComplete() throws {
        let e = try env(self)
        try e.fillWithSoundFile()                       // an EPUB annotation file, whose folder will not be readable
        let id = UUID()
        let record = PartialRecoveryRecord(id: id, title: "T", originalURL: nil, source: "# T", commentBlock: nil,
                                           updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try e.put(try JSONEncoder().encode(record), id.uuidString + ".json", .recovery)    // so there is an offer at all
        let r = try result(of: e, failing: ["EPUB Annotations"])
        XCTAssertFalse(r.isComplete)
        XCTAssertEqual(r.title, "Import not complete")
        XCTAssertTrue(r.files?.problem?.contains("could not read") == true, "the message is the same as before")
    }

    func testPostponedAttachmentsAreNotComplete() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        try e.put(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!, "p.png", .attachments)
        var flow = e.coordinator()
        flow.files.largeAttachmentsThreshold = 1
        let session = MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: false) { _ in }
        session.choose(.importNow)
        session.confirmLargeAttachments(false)
        guard case .finished(let r) = session.phase else { return XCTFail("\(session.phase)") }
        XCTAssertTrue(r.filesPostponed)
        XCTAssertEqual(r.title, "Import not complete")
    }

    func testACancelledOrFailedCopyIsNotComplete() throws {
        var cancelled = MigrationSession.MigrationResult()
        cancelled.files = FilesResultSummary(.init(state: .cancelled))
        XCTAssertEqual(cancelled.title, "Import not complete")
        XCTAssertTrue(cancelled.files?.problem?.contains("cancelled") == true)
        var failed = MigrationSession.MigrationResult()
        failed.files = FilesResultSummary(.init(state: .failed("x")))
        XCTAssertEqual(failed.title, "Import not complete")
        var settingsOnly = MigrationSession.MigrationResult()
        XCTAssertEqual(settingsOnly.title, "Import finished", "no files involved: nothing is left over")
        settingsOnly.needsRestart = true
        XCTAssertTrue(settingsOnly.isComplete)
    }

    func testTheWindowUsesTheTitleAndNoMessageChanged() throws {
        let view = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Views/MigrationView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("Text(result.title)"))
        XCTAssertFalse(view.contains("Text(\"Import finished\")"))
        XCTAssertTrue(view.contains("The attachments were not copied. Glossa will offer them again the next time it starts."))
    }
}

// MARK: - Comments and documents say what the code does

final class PhaseNineDocumentationTests: XCTestCase {
    private func text(_ path: String) throws -> String { try String(contentsOf: repositoryRoot().appendingPathComponent(path), encoding: .utf8) }

    func testTheHeadersNoLongerSayNothingCallsThem() throws {
        let migrator = try text("Glossa/Migration/AppSupportMigrator.swift")
        let scanner = try text("Glossa/Migration/AppSupportScanner.swift")
        XCTAssertFalse(migrator.contains("Not wired to anything yet"))
        XCTAssertFalse(scanner.contains("nothing calls it yet"))
        XCTAssertTrue(migrator.contains("500 MiB"), "the order of the steps names the threshold")
        XCTAssertTrue(migrator.contains("Cancelling"), "and the point of no return")
        let order = ["1. the attachments are counted", "2. scan", "3. the same threshold check", "4. files Glossa already has", "5. each file left", "6. staged files", "7. only when every file"]
        var last = migrator.startIndex
        for step in order {
            let found = try XCTUnwrap(migrator.range(of: step, range: last..<migrator.endIndex), step)
            last = found.upperBound
        }
    }

    func testTheMethodSectionDescribesTheImplementation() throws {
        let doc = try text("docs/GLOSSA-IDENTITY-SEPARATION.md")
        let start = try XCTUnwrap(doc.range(of: "**Metodo**"))
        let end = try XCTUnwrap(doc.range(of: "## 4. File recenti"))
        let method = String(doc[start.lowerBound..<end.lowerBound])
        for stale in ["rinomina in modo atomico", "per riprendere dopo", "avanzamento visibile solo", "non copiare per impostazione predefinita", "Includi i recuperi"] {
            XCTAssertFalse(method.contains(stale), stale)
        }
        for current in ["SHA-256", "O_NOFOLLOW", "non sostituisce mai", "nessun marker", "Nessuna ripresa silenziosa", "Finishing the import", "non si può più annullare", "non è del tipo", "copyItem", "1 MiB", "0700"] where current != "non è del tipo" {
            XCTAssertTrue(method.contains(current), current)
        }
        XCTAssertTrue(method.contains("non si può leggere"), "the unreadable case is described")
    }

    func testTheDocumentsExplainTheThresholdTheCountAndTheCancel() throws {
        for path in ["README.md", "docs/GLOSSA-IDENTITY-SEPARATION.md"] {
            let doc = try text(path)
            XCTAssertTrue(doc.contains("500 MiB"), path)
            XCTAssertTrue(doc.contains("Cancel") || doc.contains("annull"), path)
            XCTAssertTrue(doc.contains("link"), path)
        }
        XCTAssertTrue(try text("docs/GLOSSA-IDENTITY-SEPARATION.md").contains("limite superiore"))
        XCTAssertTrue(try text("README.md").contains("upper bound"))
    }
}

// MARK: - I3: the list of permissions and the offer

final class AuthorizationPromptTests: XCTestCase {
    func testItIsShownOnceWhenThereIsSomethingToAllow() throws {
        let e = try env(self)
        let coordinator = e.coordinator()
        XCTAssertTrue(coordinator.takeAuthorizationPrompt(pendingCount: 2))
        XCTAssertFalse(coordinator.takeAuthorizationPrompt(pendingCount: 2), "once")
    }

    func testAnEmptyListIsNotShownAndNotUsedUp() throws {
        let e = try env(self)
        let coordinator = e.coordinator()
        XCTAssertFalse(coordinator.takeAuthorizationPrompt(pendingCount: 0))
        XCTAssertNil(e.dest.value(forKey: CombinedMigrationCoordinator.authorizationPromptedKey))
        XCTAssertTrue(coordinator.takeAuthorizationPrompt(pendingCount: 1), "a later list is still shown")
    }

    func testAnOpenOfferDoesNotUseItUpOrHideIt() throws {
        let e = try env(self)
        try e.fillWithSoundFile()
        let coordinator = e.coordinator()
        XCTAssertTrue(coordinator.evaluate().hasOffer)
        XCTAssertNil(e.dest.value(forKey: CombinedMigrationCoordinator.authorizationPromptedKey), "looking at the offer does not consume it")
        XCTAssertTrue(coordinator.choose(.notNow).postponed)
        XCTAssertTrue(coordinator.takeAuthorizationPrompt(pendingCount: 3), "after Not Now the list is still shown")
    }

    func testAfterAFileOnlyImportOrARefusalItIsShownToo() throws {
        for choice in [MigrationChoice.importNow, .neverImport] {
            let e = try env(self)
            try e.fillWithSoundFile()
            let coordinator = e.coordinator()
            _ = coordinator.choose(choice)
            XCTAssertTrue(coordinator.takeAuthorizationPrompt(pendingCount: 1), "\(choice)")
            XCTAssertFalse(coordinator.takeAuthorizationPrompt(pendingCount: 1))
        }
    }

    func testTheLaunchShowsTheOffersWindowFirstAndThePermissionsAfterIt() throws {
        let presenter = try String(contentsOf: repositoryRoot().appendingPathComponent("Glossa/Migration/MigrationPresenter.swift"), encoding: .utf8)
        let launch = try XCTUnwrap(presenter.range(of: "static func presentIfNeeded"))
        let body = String(presenter[launch.lowerBound...])
        let offer = try XCTUnwrap(body.range(of: "runOffer(prompt, coordinator: coordinator) { return true }"))
        let list = try XCTUnwrap(body.range(of: "presentAuthorizations(coordinator: coordinator)"))
        XCTAssertLessThan(offer.lowerBound, list.lowerBound, "the modal offer is gone before the list's window opens")

        let runOffer = try XCTUnwrap(presenter.range(of: "private static func runOffer"))
        let end = try XCTUnwrap(presenter.range(of: "/// The first launch after an import", range: runOffer.upperBound..<presenter.endIndex))
        let offerBody = presenter[runOffer.lowerBound..<end.lowerBound]
        XCTAssertFalse(offerBody.contains("showAuthorizationManager"), "the offer's own window never opens the list")
        XCTAssertTrue(offerBody.contains("guard relaunch else { return false }"))
    }
}
