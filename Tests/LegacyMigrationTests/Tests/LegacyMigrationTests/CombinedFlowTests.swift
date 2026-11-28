import XCTest
import CryptoKit
@testable import LegacyMigration

// The offer for the two units together: A (preferences) and B (files). Every test uses temporary
// folders and in-memory preferences. Nothing of the reader's is read, and no window is shown: the
// session that drives the window is tested through its phases.

// MARK: - Helpers

private final class Mem: MigrationDestination {
    var store: [String: Any] = [:]
    var sets: [String] = []
    var failOnSet: Int?
    func value(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any, forKey key: String) throws {
        sets.append(key)
        if let failOnSet, sets.count == failOnSet { throw LegacyMigrator.Failure(reason: "disk full") }
        store[key] = value
    }
    func remove(forKey key: String) throws { store[key] = nil }
}

private final class Reads: LegacyPreferencesSource {
    let values: [String: Any]
    var count = 0
    init(_ values: [String: Any]) { self.values = values }
    func snapshot() throws -> [String: Any] { count += 1; return values }
}

private let preferencesData: [String: Any] = ["settings.showTooltips": true, "settings.toolbarScale": 1.5]

private func repositoryRoot() -> URL { (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() } }
private func source(_ name: String) throws -> String { try String(contentsOf: repositoryRoot().appendingPathComponent(name), encoding: .utf8) }
private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private func names(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

private let pngBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!

private struct RecoveryRecord: Codable {
    var id: UUID
    var title: String
    var originalURL: URL?
    var source: String
    var commentBlock: String?
    var updatedAt: Date
}

private struct Env {
    let base: URL
    let dest = Mem()
    var paths: ApplicationSupportPaths { ApplicationSupportPaths(base: base) }
    var markerURL: URL { AppSupportMarker.url(in: paths.glossaRoot) }

    /// PageFlow's folder with one file of each kind (the recovery file's name is returned).
    @discardableResult
    func fillPageFlow() throws -> String {
        let id = UUID()
        let record = RecoveryRecord(id: id, title: "T", originalURL: nil, source: "# T", commentBlock: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try put(try JSONEncoder().encode(record), id.uuidString + ".json", .recovery)
        try put(pngBytes, "Pasted image.png", .attachments)
        let object: [String: Any] = ["path": "/b.epub", "highlights": [], "bookmarks": [], "updatedAt": 1.0, "identifier": NSNull()]
        try put(try JSONSerialization.data(withJSONObject: object), sha(Data("path:/b.epub".utf8)) + ".json", .epubAnnotations)
        return id.uuidString + ".json"
    }

    func put(_ data: Data, _ name: String, _ category: ApplicationSupportPaths.Category) throws {
        let folder = paths.legacyDirectory(for: category)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }

    func coordinator(prefs: LegacyPreferencesSource? = DictionarySource(values: preferencesData), sandboxed: Bool = false, glossa: Bool = true,
                     threshold: Int64? = nil, space: Int64? = Int64.max / 4,
                     checkpoint: @escaping (AppSupportMigrator.Checkpoint) throws -> Void = { _ in }) -> CombinedMigrationCoordinator {
        var files = AppSupportMigrator(paths: ApplicationSupportPaths(base: base, legacyIsReachable: !sandboxed))
        files.availableSpace = { _ in space }
        files.checkpoint = checkpoint
        files.appVersion = "9.9"
        if let threshold { files.largeAttachmentsThreshold = threshold }
        let preferences = LegacyMigrationCoordinator(
            source: prefs ?? DictionarySource(values: [:]), destination: dest,
            migrator: LegacyMigrator(planner: LegacyMigrationPlanner(inspector: LegacyBookmarkInspector(scoped: false))),
            isGlossa: glossa, isSandboxed: sandboxed, appVersion: "9.9", applicationSupport: base)
        return CombinedMigrationCoordinator(preferences: preferences, files: files)
    }
}

private func env(_ test: XCTestCase) throws -> Env {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-combined-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    return Env(base: base)
}

private func tree(_ root: URL) -> [String] {
    var lines: [String] = []
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: []) {
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let content = values?.isDirectory == false ? sha((try? Data(contentsOf: url)) ?? Data()) : "-"
            lines.append("\(url.path.dropFirst(root.path.count))|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(content)")
        }
    }
    return lines.sorted()
}

// MARK: - A and B available or not

final class CombinedAvailabilityTests: XCTestCase {
    func testBothAreOfferedTogether() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let prompt = e.coordinator().evaluate()
        XCTAssertTrue(prompt.hasOffer)
        XCTAssertNotNil(prompt.preferences.summary)
        let offer = try XCTUnwrap(prompt.files.offer)
        XCTAssertEqual(offer.totalFiles, 3)
        XCTAssertEqual(offer.lines.map(\.category), [.recovery, .attachments, .epubAnnotations])
        XCTAssertEqual(offer.attachmentBytes, Int64(pngBytes.count))
        XCTAssertFalse(offer.interrupted)
    }

    func testTheFilesAreOfferedEvenThoughThePreferencesWereImportedEarlier() throws {
        let e = try env(self)
        try e.fillPageFlow()
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { return XCTFail() }    // as PR 4 did
        let prompt = e.coordinator().evaluate()
        XCTAssertEqual(prompt.preferences, .notNeeded(.alreadyMigrated))
        XCTAssertNotNil(prompt.files.offer, "B is offered to someone who already imported A")
        XCTAssertTrue(prompt.hasOffer)
    }

    func testThePreferencesAreOfferedWhenTheFilesAreDoneOrAbsent() throws {
        let e = try env(self)
        XCTAssertNil(e.coordinator().evaluate().files.offer)
        XCTAssertEqual(e.coordinator().evaluate().files, .unavailable(.nothingToCopy))
        XCTAssertTrue(e.coordinator().evaluate().hasOffer, "A alone is enough")

        try e.fillPageFlow()
        XCTAssertEqual(e.coordinator().choose(.importNow).files?.state, .completed)
        let after = e.coordinator().evaluate()
        XCTAssertEqual(after.files, .unavailable(.alreadyCopied))
        XCTAssertTrue(after.hasOffer == false, "both done")
    }

    func testRefusingThePreferencesForGoodMeansTheFilesAreNotOfferedEither() throws {
        // D2, in the case that matters: only A's refusal is on record (B has none), and B is still not offered.
        let e = try env(self)
        try e.fillPageFlow()
        e.dest.store[MigrationDeclined.key] = Data("{}".utf8)
        let prompt = e.coordinator().evaluate()
        XCTAssertEqual(prompt.files, .unavailable(.preferencesDeclined))
        XCTAssertFalse(prompt.hasOffer)
        XCTAssertNil(e.dest.store[AppSupportDeclined.key], "B has no refusal of its own, and none was written")
        try e.put(pngBytes, "another.png", .attachments)
        XCTAssertFalse(e.coordinator().evaluate().hasOffer, "a PageFlow folder that grew since is not offered either")
        XCTAssertNil(e.coordinator().choose(.importNow).files)

        // And "Don't Import Ever" with both offered ends the same way, through both refusals.
        let f = try env(self)
        try f.fillPageFlow()
        XCTAssertTrue(f.coordinator().choose(.neverImport).declinedPreferences)
        XCTAssertFalse(f.coordinator().evaluate().hasOffer)
    }

    func testRefusingTheFilesLeavesThePreferencesOffered() throws {
        let e = try env(self)
        try e.fillPageFlow()
        // A refusal that only B holds (as when A was imported before).
        e.dest.store[AppSupportDeclined.key] = Data("{}".utf8)
        let prompt = e.coordinator().evaluate()
        XCTAssertEqual(prompt.files, .unavailable(.declined))
        XCTAssertNotNil(prompt.preferences.summary, "A keeps its own state")
    }

    func testBothRefusedMeansNothing() throws {
        let e = try env(self)
        try e.fillPageFlow()
        e.dest.store[AppSupportDeclined.key] = Data("{}".utf8)
        e.dest.store[MigrationDeclined.key] = Data("{}".utf8)
        XCTAssertFalse(e.coordinator().evaluate().hasOffer)
    }

    func testASandboxedBuildOffersNeitherAndSaysWhy() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let reads = Reads(preferencesData)
        let prompt = e.coordinator(prefs: reads, sandboxed: true).evaluate()
        XCTAssertFalse(prompt.hasOffer)
        XCTAssertEqual(prompt.files, .unavailable(.sandboxed))
        XCTAssertTrue(prompt.isBlockedBySandbox)
        XCTAssertEqual(reads.count, 0, "PageFlow's preferences are not read")
        XCTAssertEqual(prompt.explanations.count, 2)
        XCTAssertTrue(prompt.explanations.allSatisfy { $0.contains("sandbox") })
        XCTAssertTrue(FilesUnavailableReason.sandboxed.explanation.contains("Release-Direct"))
        XCTAssertEqual(e.dest.sets.count, 0)
    }

    func testTheSandboxIsDecidedBeforePageFlowsFolderIsLookedAt() throws {
        let text = try source("Glossa/Migration/CombinedMigrationCoordinator.swift")
        let sandbox = try XCTUnwrap(text.range(of: "files.paths.legacyIsReachable"))
        let counting = try XCTUnwrap(text.range(of: "AppSupportCandidates("))
        XCTAssertLessThan(sandbox.lowerBound, counting.lowerBound)
        // And the sandboxed choice cannot run a copy either.
        let e = try env(self)
        try e.fillPageFlow()
        XCTAssertNil(e.coordinator(sandboxed: true).choose(.importNow).files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path))
    }

    func testNoPageFlowFilesMeansNothingToCopyAndOtherIdentitiesAreNotOffered() throws {
        let e = try env(self)
        XCTAssertEqual(e.coordinator(prefs: nil).evaluateFiles(), .unavailable(.nothingToCopy))
        XCTAssertEqual(e.coordinator(prefs: nil, glossa: false).evaluateFiles(), .unavailable(.notGlossa))
        try e.put(Data("x".utf8), ".hidden", .attachments)
        try FileManager.default.createDirectory(at: e.paths.legacyDirectory(for: .recovery).appendingPathComponent("sub"), withIntermediateDirectories: true)
        XCTAssertEqual(e.coordinator(prefs: nil).evaluateFiles(), .unavailable(.nothingToCopy), "hidden files and folders do not count")
    }

    func testALinkedPageFlowFolderIsNotCountedOrFollowed() throws {
        let e = try env(self)
        let elsewhere = e.base.appendingPathComponent("elsewhere/Attachments")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try pngBytes.write(to: elsewhere.appendingPathComponent("a.png"))
        try FileManager.default.createSymbolicLink(at: e.paths.legacyRoot, withDestinationURL: e.base.appendingPathComponent("elsewhere"))
        XCTAssertEqual(e.coordinator(prefs: nil).evaluateFiles(), .unavailable(.legacyFolderIsLink), "not followed, and the reason says it is a link")
    }

    func testAnInterruptedCopyIsOfferedAgainAndFlagged() throws {
        let e = try env(self)
        try e.fillPageFlow()
        var staged = 0
        let cut = e.coordinator(checkpoint: { if case .staged = $0 { staged += 1; if staged == 2 { throw AppSupportMigrator.Interrupted() } } })
        XCTAssertEqual(cut.choose(.importNow).files?.state, .failed("interrupted"))
        let prompt = e.coordinator().evaluate()
        XCTAssertEqual(prompt.files.offer?.interrupted, true, "D7: offered again, as an interrupted copy")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testAnInvalidMarkerBlocksTheOfferAndIsNeverOverwritten() throws {
        let e = try env(self)
        try e.fillPageFlow()
        try FileManager.default.createDirectory(at: e.paths.glossaRoot, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: e.markerURL)
        XCTAssertEqual(e.coordinator().evaluateFiles(), .unavailable(.markerInvalid))
        XCTAssertNil(e.coordinator().choose(.importNow).files)
        XCTAssertEqual(try Data(contentsOf: e.markerURL), Data("garbage".utf8))
    }
}

// MARK: - The three choices

final class CombinedChoiceTests: XCTestCase {
    func testImportRunsBothAndRestartsOnlyBecauseOfThePreferences() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let outcome = e.coordinator().choose(.importNow)
        XCTAssertNil(outcome.failure)
        XCTAssertTrue(outcome.needsRestart, "A was applied")
        XCTAssertEqual(outcome.files?.state, .completed)
        XCTAssertNotNil(e.dest.store[MigrationMarker.key], "A's marker")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path), "B's marker")
        XCTAssertNil(e.dest.store[MigrationDeclined.key])
        XCTAssertNil(e.dest.store[AppSupportDeclined.key])
        XCTAssertEqual(outcome.files?.copied.count, 3)
    }

    func testImportingTheFilesAloneNeedsNoRestart() throws {
        let e = try env(self)
        try e.fillPageFlow()
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { return XCTFail() }
        let writes = e.dest.sets.count
        let outcome = e.coordinator().choose(.importNow)
        XCTAssertNil(outcome.preferences, "A is not run again")
        XCTAssertEqual(outcome.files?.state, .completed)
        XCTAssertFalse(outcome.needsRestart, "B alone never restarts the app")
        XCTAssertEqual(e.dest.sets.count, writes, "no preference was written")
    }

    func testImportingThePreferencesAloneRestartsAndCopiesNothing() throws {
        let e = try env(self)     // no PageFlow files
        let outcome = e.coordinator().choose(.importNow)
        XCTAssertTrue(outcome.needsRestart)
        XCTAssertNil(outcome.files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testNotNowWritesNothingForEitherUnitAndTheOfferComesBack() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let legacy = tree(e.paths.legacyRoot)
        let outcome = e.coordinator().choose(.notNow)
        XCTAssertTrue(outcome.postponed)
        XCTAssertEqual(e.dest.sets.count, 0)
        XCTAssertTrue(e.dest.store.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path), "not even Glossa's folder")
        XCTAssertEqual(tree(e.paths.legacyRoot), legacy)
        for _ in 0..<3 { XCTAssertTrue(e.coordinator().evaluate().hasOffer, "at the next launches, too") }
    }

    func testNeverRecordsEachOfferedUnitsRefusalAndNothingElse() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let legacy = tree(e.paths.legacyRoot)
        let outcome = e.coordinator().choose(.neverImport)
        XCTAssertTrue(outcome.declinedPreferences)
        XCTAssertTrue(outcome.declinedFiles)
        XCTAssertEqual(Set(e.dest.store.keys), [MigrationDeclined.key, AppSupportDeclined.key])
        XCTAssertNotEqual(MigrationDeclined.key, AppSupportDeclined.key)
        XCTAssertNil(e.dest.store[MigrationMarker.key], "a refusal is not a completed import")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path))
        XCTAssertEqual(tree(e.paths.legacyRoot), legacy)
        XCTAssertEqual(e.dest.store.keys.filter { $0.hasPrefix("settings.") }.count, 0, "nothing was imported")
    }

    func testNeverOnlyRecordsWhatWasOffered() throws {
        // Only the files offered (A was imported before): only B's refusal.
        let e = try env(self)
        try e.fillPageFlow()
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { return XCTFail() }
        let outcome = e.coordinator().choose(.neverImport)
        XCTAssertFalse(outcome.declinedPreferences)
        XCTAssertTrue(outcome.declinedFiles)
        XCTAssertNotNil(e.dest.store[AppSupportDeclined.key])
        XCTAssertNil(e.dest.store[MigrationDeclined.key])

        // Only the preferences offered (no PageFlow files): only A's refusal.
        let f = try env(self)
        let only = f.coordinator().choose(.neverImport)
        XCTAssertTrue(only.declinedPreferences)
        XCTAssertFalse(only.declinedFiles)
        XCTAssertNil(f.dest.store[AppSupportDeclined.key])
    }

    func testTheRefusalHoldsAcrossLaunchesAndPageFlowIsNotReadAgain() throws {
        let e = try env(self)
        try e.fillPageFlow()
        _ = e.coordinator().choose(.neverImport)
        let legacy = tree(e.paths.legacyRoot)
        for _ in 0..<4 {
            let reads = Reads(preferencesData)
            let prompt = e.coordinator(prefs: reads).evaluate()
            XCTAssertFalse(prompt.hasOffer)
            XCTAssertEqual(reads.count, 0, "after a refusal PageFlow's preferences are not read")
        }
        XCTAssertEqual(tree(e.paths.legacyRoot), legacy)
    }

    func testTheFilesRefusalDoesNotStopThePreferencesAndTheOtherWayRound() throws {
        let e = try env(self)
        try e.fillPageFlow()
        e.dest.store[AppSupportDeclined.key] = Data("{}".utf8)
        let outcome = e.coordinator().choose(.importNow)
        XCTAssertTrue(outcome.needsRestart)
        XCTAssertNil(outcome.files, "B stays refused")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testAStaleWindowCannotImportWhatIsNoLongerOffered() throws {
        let e = try env(self)
        try e.fillPageFlow()
        XCTAssertEqual(e.coordinator().choose(.importNow).files?.state, .completed)
        let sets = e.dest.sets.count
        let again = e.coordinator().choose(.importNow)
        XCTAssertNil(again.files)
        XCTAssertNil(again.preferences)
        XCTAssertEqual(e.dest.sets.count, sets)

        let f = try env(self)
        try f.fillPageFlow()
        _ = f.coordinator().choose(.neverImport)
        XCTAssertNil(f.coordinator().choose(.importNow).files, "after a refusal the files cannot be copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.markerURL.path))
    }

    func testAFailureOfThePreferencesStopsTheFilesAndRecordsNothing() throws {
        let e = try env(self)
        try e.fillPageFlow()
        e.dest.failOnSet = 1
        let outcome = e.coordinator().choose(.importNow)
        XCTAssertNotNil(outcome.failure)
        XCTAssertNil(outcome.files, "B is not tried when A failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertNil(e.dest.store[MigrationMarker.key])
        XCTAssertTrue(e.coordinator().evaluate().hasOffer, "and the offer stays")
    }

    func testARefusalThatCannotBeSavedIsReported() throws {
        let e = try env(self)
        try e.fillPageFlow()
        e.dest.store[MigrationMarker.key] = Data()          // A not offered: only B's refusal is written
        e.dest.failOnSet = 1
        let outcome = e.coordinator().choose(.neverImport)
        XCTAssertNotNil(outcome.failure)
        XCTAssertFalse(outcome.declinedFiles)
        XCTAssertNil(e.dest.store[AppSupportDeclined.key])
    }

    func testThePreferencesAloneBehaveAsTheyDidInPR4() throws {
        let e = try env(self)
        let combined = e.coordinator().choose(.importNow)
        let direct = Mem()
        let plain = LegacyMigrationCoordinator(source: DictionarySource(values: preferencesData), destination: direct,
                                               migrator: LegacyMigrator(planner: LegacyMigrationPlanner(inspector: LegacyBookmarkInspector(scoped: false))),
                                               isGlossa: true, isSandboxed: false, appVersion: "9.9", applicationSupport: nil)
        _ = plain.choose(.importNow)
        XCTAssertEqual(Set(e.dest.store.keys), Set(direct.store.keys), "the same keys, the same marker")
        XCTAssertEqual(e.dest.sets.last, MigrationMarker.key, "the marker is still written last")
        XCTAssertTrue(combined.needsRestart)
    }
}

// MARK: - Large attachments, interruptions, Recovery

final class CombinedLargeAndInterruptedTests: XCTestCase {
    func testLargeAttachmentsWaitForAConfirmationAndNothingIsCopiedMeanwhile() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let outcome = e.coordinator(threshold: Int64(pngBytes.count) - 1).choose(.importNow)
        XCTAssertEqual(outcome.filesNeedConfirmation, Int64(pngBytes.count))
        XCTAssertTrue(outcome.needsRestart, "A was applied; it does not wait")
        XCTAssertNil(try? FileManager.default.contentsOfDirectory(atPath: e.paths.recovery.path), "no file was copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testConfirmingCopiesAndRecordsTheMarker() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let flow = e.coordinator(threshold: 1)
        _ = flow.choose(.importNow)
        let confirmed = flow.copyFiles(confirmLargeAttachments: true)
        XCTAssertEqual(confirmed.files?.state, .completed)
        XCTAssertFalse(confirmed.needsRestart, "B alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testNotConfirmingLeavesNoMarkerAndTheOfferReturns() throws {
        let e = try env(self)
        try e.fillPageFlow()
        _ = e.coordinator(threshold: 1).choose(.importNow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
        let prompt = e.coordinator(threshold: 1).evaluate()
        XCTAssertNotNil(prompt.files.offer, "offered again at the next launch")
        XCTAssertNil(prompt.preferences.summary, "A is done and stays done")
    }

    func testTheConfirmationStepRechecksThatTheFilesAreStillOffered() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let flow = e.coordinator(threshold: 1)
        _ = flow.choose(.neverImport)
        XCTAssertNotNil(flow.copyFiles(confirmLargeAttachments: true).failure)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testAnInterruptedCopyLeavesThePreferencesIntactAndTheNextImportOnlyFinishesTheFiles() throws {
        let e = try env(self)
        try e.fillPageFlow()
        var merged = 0
        let cut = e.coordinator(checkpoint: { if case .merged = $0 { merged += 1; if merged == 1 { throw AppSupportMigrator.Interrupted() } } })
        let first = cut.choose(.importNow)
        XCTAssertTrue(first.needsRestart)
        XCTAssertEqual(first.files?.state, .failed("interrupted"))
        XCTAssertNotNil(e.dest.store[MigrationMarker.key], "A's marker is independent of B's")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))

        let second = e.coordinator().choose(.importNow)
        XCTAssertNil(second.preferences)
        XCTAssertEqual(second.files?.state, .completed)
        XCTAssertEqual(second.files?.identical.count, 1, "what was already moved is not duplicated")
    }

    func testARecoveryCopyThatWasUsedAndRemovedIsNotBroughtBack() throws {
        let e = try env(self)
        let name = try e.fillPageFlow()
        XCTAssertEqual(e.coordinator().choose(.importNow).files?.state, .completed)
        try FileManager.default.removeItem(at: e.paths.recovery.appendingPathComponent(name))   // the note was saved; its copy dropped
        XCTAssertEqual(e.coordinator().evaluateFiles(), .unavailable(.alreadyCopied))
        let again = e.coordinator().choose(.importNow)
        XCTAssertNil(again.files)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.recovery.appendingPathComponent(name).path))
    }

    func testRecoveryIsCopiedBeforeTheStoreReadsItAndTheOfferComesBeforeRestoring() throws {
        let delegate = try source("Glossa/AppDelegate.swift")
        let offer = try XCTUnwrap(delegate.range(of: "MigrationPresenter.presentIfNeeded(recentFiles: recentFilesManager)"))
        let restoreNotes = try XCTUnwrap(delegate.range(of: "        restoreUnsavedMarkdownCopies()\n"))
        let session = try XCTUnwrap(delegate.range(of: "        restorePreviousSessionIfNeeded()\n"))
        XCTAssertLessThan(offer.lowerBound, restoreNotes.lowerBound)
        XCTAssertLessThan(offer.lowerBound, session.lowerBound)
        // The recovery store is first touched when notes are restored, which is after the offer.
        let firstUse = try XCTUnwrap(delegate.range(of: "MarkdownRecoveryStore.shared"))
        XCTAssertGreaterThan(firstUse.lowerBound, offer.lowerBound)
    }
}

// MARK: - The session behind the window

@MainActor final class MigrationSessionTests: XCTestCase {
    private final class Closed { var calls: [Bool] = [] }

    private func session(_ e: Env, _ flow: CombinedMigrationCoordinator, closed: Closed) -> MigrationSession {
        MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: false) { closed.calls.append($0) }
    }

    func testNotNowClosesWithoutWritingOrRestarting() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let closed = Closed()
        let s = session(e, e.coordinator(), closed: closed)
        s.choose(.notNow)
        XCTAssertEqual(closed.calls, [false])
        XCTAssertEqual(s.phase, .choosing)
        XCTAssertEqual(e.dest.sets.count, 0)
    }

    func testNeverClosesAndWritesBothRefusals() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let closed = Closed()
        session(e, e.coordinator(), closed: closed).choose(.neverImport)
        XCTAssertEqual(closed.calls, [false])
        XCTAssertEqual(Set(e.dest.store.keys), [MigrationDeclined.key, AppSupportDeclined.key])
    }

    func testImportingBothShowsTheResultAndOnlyThenAsksForTheRestart() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let closed = Closed()
        let s = session(e, e.coordinator(), closed: closed)
        s.choose(.importNow)
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertTrue(result.needsRestart)
        XCTAssertNotNil(result.preferences)
        XCTAssertEqual(result.files?.copiedFiles, 3)
        XCTAssertEqual(result.files?.completed, true)
        XCTAssertEqual(closed.calls, [], "the window stays until the reader presses the button")
        s.restart()
        XCTAssertEqual(closed.calls, [true])
    }

    func testImportingTheFilesAloneIsFollowedByContinueNotARestart() throws {
        let e = try env(self)
        try e.fillPageFlow()
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { return XCTFail() }
        let closed = Closed()
        let s = session(e, e.coordinator(), closed: closed)
        s.choose(.importNow)
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertFalse(result.needsRestart)
        XCTAssertNil(result.preferences)
        s.close()
        XCTAssertEqual(closed.calls, [false], "no restart for B alone")
    }

    func testLargeAttachmentsAskFirstAndCopyingFollowsTheAnswer() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let closed = Closed()
        let s = session(e, e.coordinator(threshold: 1), closed: closed)
        s.choose(.importNow)
        XCTAssertEqual(s.phase, .confirmingLargeAttachments(bytes: Int64(pngBytes.count)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path), "nothing is copied before the answer")
        s.confirmLargeAttachments(true)
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(result.files?.completed, true)
        XCTAssertTrue(result.needsRestart, "A, imported in the same step, still needs it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testDecliningTheLargeCopyCopiesNothingAndRemembersNothing() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let s = session(e, e.coordinator(threshold: 1), closed: Closed())
        s.choose(.importNow)
        s.confirmLargeAttachments(false)
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertTrue(result.filesPostponed)
        XCTAssertNil(result.files)
        XCTAssertNotNil(result.preferences, "A's result is kept")
        XCTAssertNil(e.dest.store[AppSupportDeclined.key], "postponing is not refusing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertNotNil(e.coordinator(threshold: 1).evaluate().files.offer, "offered at the next launch")
    }

    func testAnAnswerOutsideTheQuestionDoesNothing() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let s = session(e, e.coordinator(), closed: Closed())
        s.confirmLargeAttachments(true)
        XCTAssertEqual(s.phase, .choosing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testAFailureShowsItAndBackReturnsToTheChoice() throws {
        let e = try env(self)
        try e.fillPageFlow()
        e.dest.failOnSet = 1
        let closed = Closed()
        let s = session(e, e.coordinator(), closed: closed)
        s.choose(.importNow)
        guard case .failed = s.phase else { return XCTFail("\(s.phase)") }
        s.backToChoice()
        XCTAssertEqual(s.phase, .choosing)
        XCTAssertEqual(closed.calls, [])
    }

    func testTheResultNamesConflictsInvalidFilesAndTheJSONLimit() throws {
        let e = try env(self)
        let name = try e.fillPageFlow()
        try e.put(Data("{ nope".utf8), UUID().uuidString + ".json", .recovery)
        try FileManager.default.createDirectory(at: e.paths.recovery, withIntermediateDirectories: true)
        try Data("Glossa's own".utf8).write(to: e.paths.recovery.appendingPathComponent(name))      // a conflict
        let big = e.paths.legacyDirectory(for: .recovery).appendingPathComponent(UUID().uuidString + ".json")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AppSupportScanner.jsonLimit) + 1)
        try handle.close()

        let s = session(e, e.coordinator(), closed: Closed())
        s.choose(.importNow)
        guard case .finished(let result) = s.phase, let files = result.files else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(files.conflicts, 1)
        XCTAssertEqual(files.invalid, 2)
        XCTAssertEqual(files.overJSONLimit, 1)
        XCTAssertEqual(files.copiedFiles, 2)
        XCTAssertTrue(files.completed)
        XCTAssertEqual(files.lines.first { $0.category == .recovery }?.conflicts, 1)
    }

    func testTheResultSaysWhenTheCopyDidNotComplete() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let cut = e.coordinator(checkpoint: { if case .staged = $0 { throw AppSupportMigrator.Interrupted() } })
        let s = session(e, cut, closed: Closed())
        s.choose(.importNow)
        guard case .finished(let result) = s.phase, let files = result.files else { return XCTFail("\(s.phase)") }
        XCTAssertFalse(files.completed)
        XCTAssertNotNil(files.problem)
        XCTAssertTrue(files.problem?.contains("offered again") == true)
    }
}

// MARK: - The window and the menu

final class MigrationWindowWiringTests: XCTestCase {
    func testTheWindowShowsBothUnitsAndRestartsOnlyWhenTheResultSaysSo() throws {
        let view = try source("Glossa/Views/MigrationView.swift")
        for text in ["Don't Import Ever", "Not Now", "Button(\"Import\")", "session.prompt.preferences.summary", "session.prompt.files.offer",
                     "Copy \\(FilesResultSummary.mebibytes(bytes)) of attachments?", "session.confirmLargeAttachments(true)", "session.confirmLargeAttachments(false)"] {
            XCTAssertTrue(view.contains(text), text)
        }
        let restart = try XCTUnwrap(view.range(of: "if result.needsRestart {\n                    Button(\"Restart Glossa\")"))
        XCTAssertNotNil(view.range(of: "Button(\"Continue\")", range: restart.upperBound..<view.endIndex))
    }

    func testThePresenterRestartsOnlyWhenTheSessionAsksAndConfirmsTheImportFirst() throws {
        let presenter = try source("Glossa/Migration/MigrationPresenter.swift")
        XCTAssertTrue(presenter.contains("guard relaunch else { return false }"))
        XCTAssertTrue(presenter.contains("importIsRecorded(in: readback)"))
        XCTAssertTrue(presenter.contains("if prompt.hasOffer"))
        let menu = try XCTUnwrap(presenter.range(of: "static func importFromMenu()"))
        let end = try XCTUnwrap(presenter.range(of: "private static func restart", range: menu.upperBound..<presenter.endIndex))
        let body = presenter[menu.lowerBound..<end.lowerBound]
        XCTAssertFalse(body.contains("choose(") || body.contains("runOffer"), "the menu only says what is available")
    }

    func testTheSessionHasNoUserInterfaceInIt() throws {
        let text = try source("Glossa/Migration/MigrationSession.swift")
        XCTAssertFalse(text.contains("import SwiftUI") || text.contains("import AppKit") || text.contains("NSAlert"))
    }
}

// MARK: - After the preferences were applied: the restart is never lost

@MainActor final class MigrationSessionRestartTests: XCTestCase {
    private final class Closed { var calls: [Bool] = [] }

    private func session(_ flow: CombinedMigrationCoordinator, closed: Closed) -> MigrationSession {
        MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: false) { closed.calls.append($0) }
    }

    /// A applied, then the large attachments waiting for an answer.
    private func appliedAndAskingAboutAttachments(_ e: Env, closed: Closed) throws -> MigrationSession {
        try e.fillPageFlow()
        let s = session(e.coordinator(threshold: 1), closed: closed)
        s.choose(.importNow)
        XCTAssertEqual(s.phase, .confirmingLargeAttachments(bytes: Int64(pngBytes.count)))
        XCTAssertTrue(s.preferencesApplied)
        return s
    }

    func testImportThenConfirmationThenNotNowStillAsksForTheRestart() throws {
        let e = try env(self)
        let closed = Closed()
        let s = try appliedAndAskingAboutAttachments(e, closed: closed)
        s.confirmLargeAttachments(false)
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertTrue(result.needsRestart, "A was applied: the restart is needed whatever happens to B")
        XCTAssertTrue(result.filesPostponed)
        XCTAssertNotNil(result.preferences)
        XCTAssertEqual(closed.calls, [], "the window waits for the button")
        s.restart()
        XCTAssertEqual(closed.calls, [true])
        XCTAssertNil(e.dest.store[AppSupportDeclined.key])
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path), "B was postponed, not recorded")
    }

    func testEveryWayOutAfterThePreferencesWereAppliedIsARestart() throws {
        let e = try env(self)
        let closed = Closed()
        let s = try appliedAndAskingAboutAttachments(e, closed: closed)
        s.confirmLargeAttachments(false)
        s.close()                                   // even the button that normally continues
        XCTAssertEqual(closed.calls, [true])
    }

    func testAnErrorAfterAIsToldAsSuchAndCloseStillRestarts() throws {
        let e = try env(self)
        let closed = Closed()
        let s = try appliedAndAskingAboutAttachments(e, closed: closed)
        // The files stop being offered between the question and the answer.
        e.dest.store[AppSupportDeclined.key] = Data("{}".utf8)
        s.confirmLargeAttachments(true)
        guard case .failed(let reason) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertTrue(reason.contains("no longer offered"))
        XCTAssertTrue(s.preferencesApplied, "the failure did not lose it")
        XCTAssertNotNil(e.dest.store[MigrationMarker.key], "A really is applied")
        s.close()
        XCTAssertEqual(closed.calls, [true], "Close after an error is a restart, not a launch on stale stores")
    }

    func testBackAfterAnErrorAfterAKeepsTheRestartAndSaysThereIsNothingLeft() throws {
        let e = try env(self)
        let closed = Closed()
        let s = try appliedAndAskingAboutAttachments(e, closed: closed)
        e.dest.store[AppSupportDeclined.key] = Data("{}".utf8)
        s.confirmLargeAttachments(true)
        s.backToChoice()
        guard case .nothingLeft(let text) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertTrue(text.contains("nothing left to import"))
        XCTAssertTrue(s.preferencesApplied)
        s.close()
        XCTAssertEqual(closed.calls, [true])
    }

    func testAnErrorThenBackThenAnotherImportCannotEndInAContinue() throws {
        // The old path to the bug: Back, Import again with nothing offered, "Continue" on an empty result.
        let e = try env(self)
        let closed = Closed()
        let s = try appliedAndAskingAboutAttachments(e, closed: closed)
        try FileManager.default.removeItem(at: e.paths.legacyRoot)      // nothing to copy any more
        s.confirmLargeAttachments(true)
        guard case .failed = s.phase else { return XCTFail("\(s.phase)") }
        s.backToChoice()
        if case .choosing = s.phase { s.choose(.importNow) }
        guard case .nothingLeft = s.phase else { return XCTFail("\(s.phase)") }
        s.close()
        XCTAssertEqual(closed.calls, [true])
    }

    func testAnErrorBeforeAnythingWasAppliedLeavesTheLaunchAlone() throws {
        let e = try env(self)
        try e.fillPageFlow()
        e.dest.failOnSet = 1
        let closed = Closed()
        let s = session(e.coordinator(), closed: closed)
        s.choose(.importNow)
        guard case .failed = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertFalse(s.preferencesApplied)
        s.close()
        XCTAssertEqual(closed.calls, [false], "nothing was applied: no restart needed")
    }

    func testTheErrorTextSaysTheSettingsWereImportedOnlyWhenTheyWere() throws {
        let view = try source("Glossa/Views/MigrationView.swift")
        XCTAssertTrue(view.contains("Your settings were imported, but the rest could not be completed"))
        XCTAssertTrue(view.contains("if session.preferencesApplied {\n                Text(\"Your settings were imported"))
        let applied = try XCTUnwrap(view.range(of: "Your settings were imported"))
        let plain = try XCTUnwrap(view.range(of: "Nothing was recorded as done"))
        XCTAssertLessThan(applied.lowerBound, plain.lowerBound, "the plain wording is the branch for 'nothing applied'")
        XCTAssertTrue(view.contains("Button(\"Restart Glossa\") { session.close() }"))
    }
}

// MARK: - A refusal that was only half saved

@MainActor final class MigrationSessionPartialRefusalTests: XCTestCase {
    private final class Closed { var calls: [Bool] = [] }

    func testARefusalThatFailsHalfwayThenBackReevaluatesAndSaysNothingIsLeft() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let closed = Closed()
        let flow = e.coordinator()
        let s = MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: false) { closed.calls.append($0) }
        XCTAssertNotNil(s.prompt.files.offer)

        e.dest.failOnSet = 2                         // A's refusal is saved (write 1); B's is not (write 2)
        s.choose(.neverImport)
        guard case .failed = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertNotNil(e.dest.store[MigrationDeclined.key], "A's refusal did get saved")
        XCTAssertNil(e.dest.store[AppSupportDeclined.key])

        s.backToChoice()
        guard case .nothingLeft(let text) = s.phase else { return XCTFail("the offer was read again: \(s.phase)") }
        XCTAssertTrue(text.contains("nothing left to import"))
        XCTAssertTrue(text.contains("Settings: You chose not to import"), "the reason is given")
        XCTAssertFalse(s.prompt.hasOffer)
        XCTAssertEqual(closed.calls, [])
        s.close()
        XCTAssertEqual(closed.calls, [false], "nothing was applied, so no restart")
    }

    func testAnImportOfWhatIsNoLongerOfferedIsNotShownAsFinished() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let flow = e.coordinator()
        let s = MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: false) { _ in }
        // Everything is recorded as done by someone else before the button is pressed.
        e.dest.store[MigrationMarker.key] = Data()
        e.dest.store[AppSupportDeclined.key] = Data("{}".utf8)
        s.choose(.importNow)
        guard case .nothingLeft = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertFalse(s.preferencesApplied)
    }

    func testAfterBackWithSomethingStillOfferedTheWindowShowsTheCurrentOffer() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let flow = e.coordinator()
        let s = MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: false) { _ in }
        e.dest.failOnSet = 1
        s.choose(.importNow)                         // A fails: nothing recorded, still offered
        guard case .failed = s.phase else { return XCTFail("\(s.phase)") }
        e.dest.failOnSet = nil
        s.backToChoice()
        XCTAssertEqual(s.phase, .choosing)
        XCTAssertNotNil(s.prompt.preferences.summary)
        XCTAssertNotNil(s.prompt.files.offer)
    }
}

// MARK: - Two launches: A done, B postponed

@MainActor final class TwoLaunchesTests: XCTestCase {
    private final class Closed { var calls: [Bool] = [] }

    func testALaunchAfterAWasAppliedOffersOnlyBAndImportingItDoesNotRestart() throws {
        let e = try env(self)
        try e.fillPageFlow()

        // Launch 1: import, large attachments, "Not Now": A applied and restart asked, B not recorded.
        let first = Closed()
        let flow1 = e.coordinator(threshold: 1)
        let s1 = MigrationSession(prompt: flow1.evaluate(), coordinator: flow1, defersWork: false) { first.calls.append($0) }
        s1.choose(.importNow)
        s1.confirmLargeAttachments(false)
        s1.restart()
        XCTAssertEqual(first.calls, [true])
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))

        // Launch 2 (the restart): A is done, B is offered alone; nothing about A is written again.
        let preferenceWrites = e.dest.sets.count
        let flow2 = e.coordinator(threshold: 1)
        let prompt2 = flow2.evaluate()
        XCTAssertEqual(prompt2.preferences, .notNeeded(.alreadyMigrated))
        XCTAssertNotNil(prompt2.files.offer)
        let second = Closed()
        let s2 = MigrationSession(prompt: prompt2, coordinator: flow2, defersWork: false) { second.calls.append($0) }
        s2.choose(.importNow)
        XCTAssertEqual(s2.phase, .confirmingLargeAttachments(bytes: Int64(pngBytes.count)))
        XCTAssertFalse(s2.preferencesApplied)
        s2.confirmLargeAttachments(true)
        guard case .finished(let result) = s2.phase else { return XCTFail("\(s2.phase)") }
        XCTAssertFalse(result.needsRestart, "B alone never restarts")
        XCTAssertNil(result.preferences)
        XCTAssertEqual(result.files?.completed, true)
        s2.close()
        XCTAssertEqual(second.calls, [false])
        XCTAssertEqual(e.dest.sets.count, preferenceWrites, "no preference key was written at the second launch")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))

        // Launch 3: everything is done.
        XCTAssertFalse(e.coordinator(threshold: 1).evaluate().hasOffer)
    }

    func testPostponingBAgainAtTheSecondLaunchChangesNothingAndItIsOfferedAtTheThird() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let flow1 = e.coordinator(threshold: 1)
        let s1 = MigrationSession(prompt: flow1.evaluate(), coordinator: flow1, defersWork: false) { _ in }
        s1.choose(.importNow)
        s1.confirmLargeAttachments(false)

        let writes = e.dest.sets.count
        let legacy = tree(e.paths.legacyRoot)
        let closed = Closed()
        let flow2 = e.coordinator(threshold: 1)
        let s2 = MigrationSession(prompt: flow2.evaluate(), coordinator: flow2, defersWork: false) { closed.calls.append($0) }
        s2.choose(.notNow)
        XCTAssertEqual(closed.calls, [false], "A was applied at launch 1 and already restarted: no restart now")
        XCTAssertEqual(e.dest.sets.count, writes)
        XCTAssertEqual(tree(e.paths.legacyRoot), legacy)
        XCTAssertNotNil(e.coordinator(threshold: 1).evaluate().files.offer)
    }

    func testRefusingBAtTheSecondLaunchLeavesAsMarkerAndRecordsOnlyB() throws {
        let e = try env(self)
        try e.fillPageFlow()
        let flow1 = e.coordinator(threshold: 1)
        let s1 = MigrationSession(prompt: flow1.evaluate(), coordinator: flow1, defersWork: false) { _ in }
        s1.choose(.importNow)
        s1.confirmLargeAttachments(false)

        let flow2 = e.coordinator(threshold: 1)
        let s2 = MigrationSession(prompt: flow2.evaluate(), coordinator: flow2, defersWork: false) { _ in }
        s2.choose(.neverImport)
        XCTAssertNotNil(e.dest.store[AppSupportDeclined.key])
        XCTAssertNil(e.dest.store[MigrationDeclined.key], "A's state is its own: it was imported, not refused")
        XCTAssertNotNil(e.dest.store[MigrationMarker.key])
        XCTAssertFalse(e.coordinator(threshold: 1).evaluate().hasOffer)
    }
}

// MARK: - Labels and documentation

final class LabelsAndDocumentationTests: XCTestCase {
    func testSizesAreWrittenInMiBBecauseTheyAreBinary() throws {
        XCTAssertEqual(FilesResultSummary.mebibytes(3 * 1_048_576), "3 MiB")
        XCTAssertEqual(FilesResultSummary.mebibytes(0), "0 MiB")
        for file in ["Glossa/Views/MigrationView.swift", "Glossa/Migration/CombinedMigrationCoordinator.swift", "Glossa/Migration/AppSupportMigrator.swift",
                     "Glossa/Migration/AppSupportOffer.swift"] {
            let code = try source(file).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            XCTAssertFalse(code.contains(" MB\"") || code.contains(" MB.") || code.contains(" MB "), "\(file) still says MB")
            XCTAssertFalse(code.contains("megabytes"), file)
        }
        XCTAssertTrue(try source("Glossa/Views/MigrationView.swift").contains("larger than 500 MiB"))
    }

    func testTheDocumentationDescribesTheNewPaths() throws {
        let readme = try source("README.md")
        let identity = try source("docs/GLOSSA-IDENTITY-SEPARATION.md")
        for (name, text) in [("README", readme), ("identity doc", identity)] {
            for needle in ["64 MiB", "500 MiB", ".migration-appsupport-v1.json", "glossa.migration.appSupport.declined.v1", "Release-Direct"] {
                XCTAssertTrue(text.contains(needle), "\(name) does not mention \(needle)")
            }
        }
        XCTAssertTrue(readme.contains("Glossa's wins") || readme.contains("**Glossa's wins**"))
        XCTAssertFalse(readme.contains("still use `~/Library/Application Support/PageFlow` for now"), "the README no longer says the stores use PageFlow's folder")
        XCTAssertFalse(identity.contains("continuano temporaneamente a usare"), "nor does the identity document")
        XCTAssertTrue(identity.contains("Stato dopo la PR 5"))
    }
}
