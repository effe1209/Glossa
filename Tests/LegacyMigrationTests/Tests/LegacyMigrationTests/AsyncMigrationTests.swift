import XCTest
import CryptoKit
@testable import LegacyMigration

// Phase 6: the large-attachments question comes before anything is hashed, the work runs off the main
// actor, and it can be cancelled cleanly. Temporary folders and in-memory preferences only.

// MARK: - Helpers

private final class Mem: MigrationDestination {
    var store: [String: Any] = [:]
    var failFirstSet = false
    func value(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any, forKey key: String) throws {
        if failFirstSet { failFirstSet = false; throw LegacyMigrator.Failure(reason: "disk full") }
        store[key] = value
    }
    func remove(forKey key: String) throws { store[key] = nil }
}

/// Records which folders were listed, to tell a count of files (one listing) from a scan (another).
private final class CountingFileManager: FileManager, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func listings(of suffix: String) -> Int { lock.lock(); defer { lock.unlock() }; return paths.filter { $0.hasSuffix(suffix) }.count }
    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        lock.lock(); paths.append(path); lock.unlock()
        return try super.contentsOfDirectory(atPath: path)
    }
}

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
    let fileManager: FileManager
    var paths: ApplicationSupportPaths { ApplicationSupportPaths(base: base) }
    var markerURL: URL { AppSupportMarker.url(in: paths.glossaRoot) }
    var attachmentsFolderSuffix: String { "PageFlow/Attachments" }

    func put(_ data: Data, _ name: String, _ category: ApplicationSupportPaths.Category) throws {
        let folder = paths.legacyDirectory(for: category)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(name))
    }

    func fill() throws {
        let id = UUID()
        let record = RecoveryRecord(id: id, title: "T", originalURL: nil, source: "# T", commentBlock: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try put(try JSONEncoder().encode(record), id.uuidString + ".json", .recovery)
        try put(pngBytes, "Pasted image.png", .attachments)
        let object: [String: Any] = ["path": "/b.epub", "highlights": [], "bookmarks": [], "updatedAt": 1.0, "identifier": NSNull()]
        try put(try JSONSerialization.data(withJSONObject: object), sha(Data("path:/b.epub".utf8)) + ".json", .epubAnnotations)
    }

    func migrator(threshold: Int64? = nil, space: Int64? = Int64.max / 4,
                  checkpoint: @escaping (AppSupportMigrator.Checkpoint) throws -> Void = { _ in },
                  isCancelled: @escaping () -> Bool = { false },
                  onRunID: (() -> Void)? = nil) -> AppSupportMigrator {
        var m = AppSupportMigrator(paths: paths, fileManager: fileManager)
        if let onRunID { m.makeRunID = { onRunID(); return UUID().uuidString } }
        m.availableSpace = { _ in space }
        m.checkpoint = checkpoint
        m.isCancelled = isCancelled
        if let threshold { m.largeAttachmentsThreshold = threshold }
        return m
    }

    func coordinator(threshold: Int64? = nil, space: Int64? = Int64.max / 4,
                     checkpoint: @escaping (AppSupportMigrator.Checkpoint) throws -> Void = { _ in },
                     onRunID: (() -> Void)? = nil) -> CombinedMigrationCoordinator {
        let preferences = LegacyMigrationCoordinator(
            source: DictionarySource(values: ["settings.showTooltips": true]), destination: dest,
            migrator: LegacyMigrator(planner: LegacyMigrationPlanner(inspector: LegacyBookmarkInspector(scoped: false))),
            isGlossa: true, isSandboxed: false, appVersion: "9.9", applicationSupport: base)
        return CombinedMigrationCoordinator(preferences: preferences, files: migrator(threshold: threshold, space: space, checkpoint: checkpoint, onRunID: onRunID))
    }
}

private func env(_ test: XCTestCase, fileManager: FileManager = .default) throws -> Env {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-async-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    return Env(base: base, fileManager: fileManager)
}

private func tree(_ root: URL) -> [String] {
    var lines: [String] = []
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: []) {
        for case let url as URL in files {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let content = v?.isDirectory == false ? sha((try? Data(contentsOf: url)) ?? Data()) : "-"
            lines.append("\(url.path.dropFirst(root.path.count))|\(v?.fileSize ?? -1)|\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(content)")
        }
    }
    return lines.sorted()
}

// MARK: - The threshold comes before the scan

final class ThresholdBeforeScanTests: XCTestCase {
    func testOverTheThresholdTheReaderIsAskedBeforeAnythingIsScanned() throws {
        let counting = CountingFileManager()
        let e = try env(self, fileManager: counting)
        try e.fill()
        let report = e.migrator(threshold: Int64(pngBytes.count) - 1).run()
        XCTAssertEqual(report.state, .needsConfirmation(attachmentBytes: Int64(pngBytes.count)))
        XCTAssertNil(report.scan, "no scan, so no file was hashed or opened")
        XCTAssertEqual(counting.listings(of: "PageFlow/Attachments"), 1, "the count of files only")
        XCTAssertEqual(counting.listings(of: "PageFlow/Recovery"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path), "nothing written")
    }

    func testAfterTheConfirmationThereIsOneScanAndThenTheCopy() throws {
        let counting = CountingFileManager()
        let e = try env(self, fileManager: counting)
        try e.fill()
        let migrator = e.migrator(threshold: 1)
        XCTAssertEqual(migrator.run().state, .needsConfirmation(attachmentBytes: Int64(pngBytes.count)))
        XCTAssertEqual(counting.listings(of: "PageFlow/Attachments"), 1)

        let report = migrator.run(confirmLargeAttachments: true)
        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(counting.listings(of: "PageFlow/Attachments"), 4, "the first run counted once; the second counted once more, checked that the folders can be read, and scanned exactly once")
        XCTAssertEqual(report.copied.count, 3)
    }

    func testTheSizeCountsEveryRegularVisibleFileIncludingOnesThatMayNotBeSound() throws {
        let e = try env(self)
        try e.fill()
        try e.put(Data(repeating: 0x41, count: 100), "bad.png", .attachments)        // not an image
        try e.put(Data(repeating: 0x42, count: 50), ".hidden.png", .attachments)     // not counted
        let migrator = e.migrator(threshold: Int64(pngBytes.count) + 5)
        XCTAssertEqual(migrator.run().state, .needsConfirmation(attachmentBytes: Int64(pngBytes.count) + 100), "an upper bound, from sizes alone")
    }

    func testAtOrUnderTheThresholdNothingIsAsked() throws {
        let e = try env(self)
        try e.fill()
        XCTAssertEqual(e.migrator(threshold: Int64(pngBytes.count)).run().state, .completed)
    }

    func testOnlyAttachmentsCountTowardTheThreshold() throws {
        let e = try env(self)
        try e.fill()
        try e.put(Data(repeating: 0x20, count: 4096) + Data("{}".utf8), UUID().uuidString + ".json", .recovery)    // large, invalid, not an attachment
        XCTAssertEqual(e.migrator(threshold: Int64(pngBytes.count)).run().state, .completed)
    }

    func testTheCheckOnWhatTheScanFoundSoundStaysAsASafetyNet() throws {
        let text = try source("PageFlow/Migration/AppSupportMigrator.swift")
        XCTAssertTrue(text.contains("The same check on what the scan found sound"))
        let early = try XCTUnwrap(text.range(of: "counter.lines()"))
        let scan = try XCTUnwrap(text.range(of: "let scan = scanner.scan()"))
        XCTAssertLessThan(early.lowerBound, scan.lowerBound, "the threshold is asked of the count before the scan")
    }
}

// MARK: - Cancelling the engine

final class CancellationEngineTests: XCTestCase {
    func testCancelledBeforeTheScanNothingIsReadOrWritten() throws {
        let e = try env(self)
        try e.fill()
        let legacy = tree(e.paths.legacyRoot)
        let report = e.migrator(isCancelled: { true }).run()
        XCTAssertEqual(report.state, .cancelled)
        XCTAssertNil(report.scan)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.paths.glossaRoot.path))
        XCTAssertEqual(tree(e.paths.legacyRoot), legacy)
    }

    func testCancelledWhileStagingLeavesNoStagingNoMarkerAndNothingInPlace() throws {
        let e = try env(self)
        try e.fill()
        let legacy = tree(e.paths.legacyRoot)
        var cancel = false
        var staged = 0
        let migrator = e.migrator(checkpoint: { if case .staged = $0 { staged += 1; if staged == 1 { cancel = true } } }, isCancelled: { cancel })
        let report = migrator.run()
        XCTAssertEqual(report.state, .cancelled)
        XCTAssertEqual(report.entries, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertEqual(names(e.paths.glossaRoot).filter { $0.hasPrefix(".import-staging") }, [], "our staging is removed")
        for category in ApplicationSupportPaths.Category.allCases {
            XCTAssertEqual(names(e.paths.directory(for: category)), [], "nothing reached a final folder")
        }
        XCTAssertEqual(tree(e.paths.legacyRoot), legacy)
        XCTAssertEqual(migrator.status(), .notStarted, "not interrupted and not complete: just not done")
        // And the next run, not cancelled, does the whole copy.
        let again = e.migrator().run()
        XCTAssertEqual(again.state, .completed)
        XCTAssertEqual(again.copied.count, 3)
    }

    func testCancelledAfterEveryFileIsStagedStillMovesNothing() throws {
        let e = try env(self)
        try e.fill()
        var cancel = false
        var staged = 0
        let migrator = e.migrator(checkpoint: { if case .staged = $0 { staged += 1; if staged == 3 { cancel = true } } }, isCancelled: { cancel })
        XCTAssertEqual(migrator.run().state, .cancelled, "the last point at which a run can be stopped")
        for category in ApplicationSupportPaths.Category.allCases { XCTAssertEqual(names(e.paths.directory(for: category)), []) }
        XCTAssertEqual(names(e.paths.glossaRoot).filter { $0.hasPrefix(".import-staging") }, [])
    }

    func testOnceFilesAreBeingMovedTheRunGoesOnToTheEndAndRecordsItself() throws {
        let e = try env(self)
        try e.fill()
        var cancel = false
        let migrator = e.migrator(checkpoint: { if case .merged = $0 { cancel = true } }, isCancelled: { cancel })
        let report = migrator.run()
        XCTAssertEqual(report.state, .completed, "past the point of no return a cancel is ignored: never half-moved")
        XCTAssertEqual(report.copied.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testACancelledRunIsOfferedAgainNotMarked() throws {
        let e = try env(self)
        try e.fill()
        let coordinator = e.coordinator()
        var cancel = true
        let outcome = coordinator.choose(.importNow, isCancelled: { cancel })
        XCTAssertEqual(outcome.files?.state, .cancelled)
        XCTAssertTrue(outcome.needsRestart, "A (a short step, never cut off) was applied")
        cancel = false
        XCTAssertNotNil(e.coordinator().evaluateFiles().offer, "B is offered again")
        XCTAssertNil(e.dest.store[AppSupportDeclined.key], "cancelling is not refusing")
    }

    func testTheScannerStopsBetweenFilesAndBetweenChunks() throws {
        let e = try env(self)
        try e.fill()
        let none = AppSupportScanner(paths: e.paths, fileManager: e.fileManager, isCancelled: { true }).scan()
        XCTAssertEqual(none.categories.flatMap(\.files), [], "no file was examined")

        // A file of several chunks, cancelled after the first: not hashed, reported as cancelled.
        var big = pngBytes
        big.append(Data(repeating: 0, count: 3 * 1024 * 1024))
        try e.put(big, "zz-big.png", .attachments)
        var calls = 0
        let scanner = AppSupportScanner(paths: e.paths, fileManager: e.fileManager, isCancelled: { calls += 1; return calls >= 6 })
        let report = scanner.scan()
        let flagged = report.invalidFiles.filter { $0.verdict == .invalid(.unreadable("cancelled")) }
        XCTAssertEqual(flagged.count, 1)
        XCTAssertNil(flagged.first?.sha256)
        XCTAssertEqual(flagged.first?.name, "zz-big.png")
    }

    func testCancellingNeverTouchesThePageFlowFolderOrWritesAMarker() throws {
        let e = try env(self)
        try e.fill()
        let legacy = tree(e.paths.legacyRoot)
        for point in 1...3 {
            var staged = 0
            var cancel = false
            _ = e.migrator(checkpoint: { if case .staged = $0 { staged += 1; if staged == point { cancel = true } } }, isCancelled: { cancel }).run()
            XCTAssertEqual(tree(e.paths.legacyRoot), legacy)
            XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
        }
    }
}

// MARK: - The session runs it off the main actor

@MainActor
final class AsyncSessionTests: XCTestCase {
    private final class Closed { var calls: [Bool] = [] }
    private final class Threads: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Bool] = []
        func record() { lock.lock(); seen.append(Thread.isMainThread); lock.unlock() }
        var onMain: [Bool] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    private func session(_ flow: CombinedMigrationCoordinator, closed: Closed = Closed()) -> MigrationSession {
        MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: true) { closed.calls.append($0) }
    }

    func testTheImportIsShownAsRunningAtOnceAndFinishesWithoutBlockingTheCaller() async throws {
        let e = try env(self)
        try e.fill()
        let s = session(e.coordinator())
        s.choose(.importNow)
        XCTAssertEqual(s.phase, .running, "the work has not run: it is on another task")
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
        await s.waitForWork()
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(result.files?.completed, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertFalse(s.isCancelling)
    }

    func testTheCopyRunsOffTheMainThreadAndThePhaseChangesOnIt() async throws {
        let e = try env(self)
        try e.fill()
        let engine = Threads()
        let s = session(e.coordinator(checkpoint: { _ in engine.record() }))

        let changes = Threads()
        func watch() {
            withObservationTracking({ _ = s.phase }, onChange: { changes.record(); Task { @MainActor in watch() } })
        }
        watch()
        s.choose(.importNow)
        await s.waitForWork()
        XCTAssertFalse(engine.onMain.isEmpty)
        XCTAssertEqual(Set(engine.onMain), [false], "scan, hashing and copy never ran on the main thread")
        XCTAssertTrue(changes.onMain.allSatisfy { $0 }, "the phase only changes on the main thread")
        XCTAssertFalse(changes.onMain.isEmpty)
    }

    func testCancellingAMidCopyStopsItCleanlyAndTheResultSaysSo() async throws {
        let e = try env(self)
        try e.fill()
        // A done earlier, so only the files are in play.
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { return XCTFail() }

        let reached = expectation(description: "the copy is in progress")
        let proceed = DispatchSemaphore(value: 0)
        var first = true
        let closed = Closed()
        let s = session(e.coordinator(checkpoint: { point in
            if case .staged = point, first { first = false; reached.fulfill(); proceed.wait() }     // on the background task
        }), closed: closed)
        s.choose(.importNow)
        await fulfillment(of: [reached], timeout: 10)
        XCTAssertEqual(s.phase, .running)

        s.cancel()
        XCTAssertTrue(s.isCancelling)
        proceed.signal()
        await s.waitForWork()

        guard case .finished(let result) = s.phase, let files = result.files else { return XCTFail("\(s.phase)") }
        XCTAssertFalse(files.completed)
        XCTAssertTrue(files.problem?.contains("cancelled") == true)
        XCTAssertFalse(result.needsRestart, "B alone")
        XCTAssertFalse(s.isCancelling)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path), "no marker for a cancelled copy")
        XCTAssertEqual(names(e.paths.glossaRoot).filter { $0.hasPrefix(".import-staging") }, [])
        XCTAssertNil(e.dest.store[AppSupportDeclined.key])
        XCTAssertNotNil(e.coordinator().evaluateFiles().offer, "offered again at the next launch")
        s.close()
        XCTAssertEqual(closed.calls, [false])
    }

    func testACancelAfterTheAppliedPreferencesStillAsksForTheRestart() async throws {
        let e = try env(self)
        try e.fill()
        let reached = expectation(description: "the copy is in progress")
        let proceed = DispatchSemaphore(value: 0)
        var first = true
        let closed = Closed()
        let s = session(e.coordinator(checkpoint: { point in
            if case .staged = point, first { first = false; reached.fulfill(); proceed.wait() }
        }), closed: closed)
        s.choose(.importNow)                                   // A and B
        await fulfillment(of: [reached], timeout: 10)
        s.cancel()
        proceed.signal()
        await s.waitForWork()
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertTrue(result.needsRestart, "A was applied before the copy began")
        XCTAssertTrue(s.preferencesApplied)
        XCTAssertNotEqual(result.files?.completed, true, "the copy did not complete")
        s.close()
        XCTAssertEqual(closed.calls, [true])
    }

    func testCancelOutsideARunOrAfterItIsHarmless() async throws {
        let e = try env(self)
        try e.fill()
        let s = session(e.coordinator())
        s.cancel()
        XCTAssertEqual(s.phase, .choosing)
        XCTAssertFalse(s.isCancelling)
        s.choose(.importNow)
        await s.waitForWork()
        let phase = s.phase
        s.cancel()
        XCTAssertEqual(s.phase, phase, "a finished import is not undone by a late cancel")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testTheLargeAttachmentsQuestionIsAskedWithoutAScanAndTheAnswerRunsOnce() async throws {
        let counting = CountingFileManager()
        let e = try env(self, fileManager: counting)
        try e.fill()
        let s = session(e.coordinator(threshold: 1))
        s.choose(.importNow)
        await s.waitForWork()
        XCTAssertEqual(s.phase, .confirmingLargeAttachments(bytes: Int64(pngBytes.count)))
        XCTAssertEqual(counting.listings(of: "PageFlow/Attachments"), 5, "listings only, no scan: two for each look at the offer (the count and the check that it can be read: the window, the choice) and one for the engine's count")

        s.confirmLargeAttachments(true)
        XCTAssertEqual(s.phase, .running)
        await s.waitForWork()
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(result.files?.completed, true)
        XCTAssertEqual(counting.listings(of: "PageFlow/Attachments"), 10, "five more: the re-check (two), the engine's count, the check that folders can be read, and exactly one scan")
    }

    func testAnErrorOfTheEngineIsReportedAndLeavesNothingBehind() async throws {
        let e = try env(self)
        try e.fill()
        let s = session(e.coordinator(space: 1))
        s.choose(.importNow)
        await s.waitForWork()
        guard case .finished(let result) = s.phase, let files = result.files else { return XCTFail("\(s.phase)") }
        XCTAssertFalse(files.completed)
        XCTAssertTrue(files.problem?.contains("not enough free space") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertNil(e.dest.store[AppSupportDeclined.key])
    }

    func testTheSessionHandsTheWorkToABackgroundTaskAndOnlyItChangesThePhase() throws {
        let text = try source("PageFlow/Migration/MigrationSession.swift")
        XCTAssertTrue(text.contains("@MainActor\n@Observable\nfinal class MigrationSession"))
        XCTAssertTrue(text.contains("Task.detached(priority: .userInitiated)"))
        XCTAssertTrue(text.contains("withTaskCancellationHandler"))
        XCTAssertTrue(text.contains("deinit { work?.cancel() }"))
        let view = try source("PageFlow/Views/MigrationView.swift")
        XCTAssertTrue(view.contains("Button(\"Cancel\") { session.cancel() }"))
    }
}

// MARK: - One job at a time; a refused call changes nothing

@MainActor
final class SessionReentrancyTests: XCTestCase {
    private final class Closed { var calls: [Bool] = [] }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        private var inFlight = 0
        private var peak = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        func enter() { lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock() }
        func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peak }
    }
    /// The phases the session went through, recorded as they change.
    @MainActor private final class PhaseLog {
        var phases: [MigrationSession.Phase] = []
        func watch(_ s: MigrationSession) {
            phases.append(s.phase)
            withObservationTracking({ _ = s.phase }, onChange: { [self] in Task { @MainActor in watch(s) } })
        }
        func count(_ match: (MigrationSession.Phase) -> Bool) -> Int { phases.filter(match).count }
    }

    private func isFinished(_ p: MigrationSession.Phase) -> Bool { if case .finished = p { return true } else { return false } }

    private func session(_ flow: CombinedMigrationCoordinator, closed: Closed = Closed()) -> MigrationSession {
        MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: true) { closed.calls.append($0) }
    }

    /// A is done, so the only job is the file copy; it is held at its first staged file until released.
    private func holdingCopy(_ e: Env, closed: Closed, runs: Counter, release: DispatchSemaphore, reached: XCTestExpectation) throws -> MigrationSession {
        try e.fill()
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { XCTFail("A"); throw CancellationError() }
        var first = true
        let flow = e.coordinator(checkpoint: { point in
            switch point {
            case .stagingCreated: runs.enter()
            case .staged where first: first = false; reached.fulfill(); release.wait()      // the background task waits here
            case .beforeMarker: runs.leave()
            default: break
            }
        }, onRunID: { runs.bump() })
        return session(flow, closed: closed)
    }

    func testASecondChooseRightAfterTheFirstIsRefusedAndOnlyOneJobRuns() async throws {
        let e = try env(self)
        try e.fill()
        let runs = Counter()
        let closed = Closed()
        let s = session(e.coordinator(checkpoint: { point in
            if point == .stagingCreated { runs.enter() }
            if point == .beforeMarker { runs.leave() }
        }, onRunID: { runs.bump() }), closed: closed)
        let log = PhaseLog()
        log.watch(s)

        XCTAssertTrue(s.choose(.importNow))
        XCTAssertFalse(s.choose(.importNow), "the second call, before the task even started")
        XCTAssertFalse(s.choose(.importNow))
        XCTAssertEqual(s.phase, .running)
        await s.waitForWork()
        await Task.yield()

        XCTAssertEqual(runs.count, 1, "one run of the engine")
        XCTAssertEqual(runs.maxConcurrent, 1)
        XCTAssertEqual(log.count(isFinished), 1, "one result, shown once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertEqual(closed.calls, [])
    }

    func testEveryActionDuringARunIsRefusedAndTheFirstJobFinishesWithOneResult() async throws {
        let e = try env(self)
        let runs = Counter()
        let closed = Closed()
        let release = DispatchSemaphore(value: 0)
        let reached = expectation(description: "the copy is held")
        let s = try holdingCopy(e, closed: closed, runs: runs, release: release, reached: reached)
        let log = PhaseLog()
        log.watch(s)

        XCTAssertTrue(s.choose(.importNow))
        await fulfillment(of: [reached], timeout: 10)
        XCTAssertEqual(s.phase, .running)
        let before = (s.phase, s.preferencesApplied, s.isCancelling)

        // Everything the window could be asked to do, while the job holds the coordinator.
        XCTAssertFalse(s.choose(.importNow))
        XCTAssertFalse(s.choose(.notNow))
        XCTAssertFalse(s.choose(.neverImport))
        XCTAssertFalse(s.close())
        XCTAssertFalse(s.restart())
        XCTAssertFalse(s.backToChoice())
        XCTAssertFalse(s.confirmLargeAttachments(true))
        XCTAssertFalse(s.confirmLargeAttachments(false))

        XCTAssertEqual(s.phase, before.0, "the phase did not move")
        XCTAssertEqual(s.preferencesApplied, before.1)
        XCTAssertEqual(s.isCancelling, before.2)
        XCTAssertEqual(closed.calls, [], "the window was not left")
        XCTAssertNil(e.dest.store[AppSupportDeclined.key], "no refusal was written by a refused call")
        XCTAssertNil(e.dest.store[MigrationDeclined.key])
        XCTAssertEqual(runs.maxConcurrent, 1)

        release.signal()
        await s.waitForWork()
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(result.files?.completed, true, "the first job went on and finished")
        XCTAssertEqual(result.files?.copiedFiles, 3)
        XCTAssertEqual(runs.count, 1, "and it was the only one")
        XCTAssertEqual(runs.maxConcurrent, 1)
        XCTAssertEqual(log.count(isFinished), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertNil(e.dest.store[AppSupportDeclined.key])
        XCTAssertEqual(closed.calls, [])
    }

    func testChooseDuringRunningAfterAValidRestartRequestStillChangesNothing() async throws {
        // A applied in the same session as a job in flight: a refused restart must not leak the flag or leave.
        let e = try env(self)
        try e.fill()
        let reached = expectation(description: "held")
        let release = DispatchSemaphore(value: 0)
        var first = true
        let closed = Closed()
        let s = session(e.coordinator(checkpoint: { point in
            if case .staged = point, first { first = false; reached.fulfill(); release.wait() }
        }), closed: closed)
        XCTAssertTrue(s.choose(.importNow))                 // A and B
        await fulfillment(of: [reached], timeout: 10)
        XCTAssertFalse(s.restart(), "even though A is applied, a job is running")
        XCTAssertFalse(s.close())
        XCTAssertEqual(closed.calls, [])
        release.signal()
        await s.waitForWork()
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertTrue(result.needsRestart)
        XCTAssertTrue(s.preferencesApplied)
        XCTAssertTrue(s.restart(), "now it is allowed, once")
        XCTAssertEqual(closed.calls, [true])
        XCTAssertFalse(s.restart(), "and not a second time")
        XCTAssertFalse(s.close())
        XCTAssertEqual(closed.calls, [true])
    }

    func testCloseAndRestartAreRefusedWhileChoosingOrAsking() async throws {
        let e = try env(self)
        try e.fill()
        let closed = Closed()
        let s = session(e.coordinator(threshold: 1), closed: closed)
        XCTAssertFalse(s.close())
        XCTAssertFalse(s.restart())
        XCTAssertFalse(s.backToChoice())
        XCTAssertFalse(s.confirmLargeAttachments(true))
        XCTAssertEqual(s.phase, .choosing)
        XCTAssertEqual(closed.calls, [])

        XCTAssertTrue(s.choose(.importNow))                 // A applied, then the question about large attachments
        await s.waitForWork()
        XCTAssertEqual(s.phase, .confirmingLargeAttachments(bytes: Int64(pngBytes.count)))
        let applied = s.preferencesApplied
        XCTAssertTrue(applied)
        XCTAssertFalse(s.close())
        XCTAssertFalse(s.restart())
        XCTAssertFalse(s.choose(.importNow))
        XCTAssertFalse(s.choose(.neverImport))
        XCTAssertFalse(s.backToChoice())
        XCTAssertEqual(s.phase, .confirmingLargeAttachments(bytes: Int64(pngBytes.count)), "the question is still there")
        XCTAssertEqual(closed.calls, [])
        XCTAssertNil(e.dest.store[AppSupportDeclined.key])

        XCTAssertTrue(s.confirmLargeAttachments(false), "only the answer moves it on")
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertTrue(result.needsRestart, "the result kept what A had set")
        XCTAssertTrue(result.filesPostponed)
    }

    func testAFinishedSessionTakesNoMoreChoicesAndRunsNoMoreJobs() async throws {
        let e = try env(self)
        try e.fill()
        let runs = Counter()
        let closed = Closed()
        let s = session(e.coordinator(onRunID: { runs.bump() }), closed: closed)
        XCTAssertTrue(s.choose(.importNow))
        await s.waitForWork()
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        let sets = e.dest.store.count
        XCTAssertFalse(s.choose(.importNow), "a result on screen is not a choice")
        XCTAssertFalse(s.choose(.notNow))
        XCTAssertFalse(s.choose(.neverImport))
        XCTAssertFalse(s.confirmLargeAttachments(true))
        XCTAssertFalse(s.backToChoice())
        XCTAssertEqual(s.phase, .finished(result), "the result is the same one")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(e.dest.store.count, sets, "nothing was written by refused calls")

        XCTAssertTrue(s.restart() || s.close())              // one way out, once
        XCTAssertFalse(s.close())
        XCTAssertFalse(s.restart())
        XCTAssertEqual(closed.calls.count, 1, "the window is left once")
    }

    func testAnErrorPhaseAcceptsBackCloseOrRestartOnlyAsItShould() async throws {
        let e = try env(self)
        try e.fill()
        e.dest.failOnSetForReentrancy()
        let closed = Closed()
        let s = session(e.coordinator(), closed: closed)
        XCTAssertTrue(s.choose(.importNow))
        await s.waitForWork()
        guard case .failed = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertFalse(s.choose(.importNow), "an error is not a choice either")
        XCTAssertFalse(s.restart(), "nothing was applied, so there is nothing to restart for")
        XCTAssertEqual(closed.calls, [])
        XCTAssertTrue(s.backToChoice())
        XCTAssertEqual(s.phase, .choosing)
    }

    func testTheCoordinatorIsOnlyUsedByTheJobWhileItRuns() throws {
        let text = try source("PageFlow/Migration/MigrationSession.swift")
        // Every place the session touches the coordinator is behind a guard on `jobInFlight` or runs inside the job.
        XCTAssertEqual(text.components(separatedBy: "!jobInFlight").count - 1, 6, "choose, confirm, restart, close, backToChoice and perform's guard")
        XCTAssertTrue(text.contains("guard !jobInFlight else { return }"))
        XCTAssertTrue(text.contains("jobInFlight = true"))
        XCTAssertEqual(text.components(separatedBy: "jobInFlight = false").count - 1, 3, "its declaration, and cleared where the outcome comes back in both modes")
    }
}

// MARK: - Phase 11: the point of no return is signalled

final class PointOfNoReturnEngineTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
        func bump() { lock.lock(); n += 1; lock.unlock() }
    }

    func testItIsSignalledOnceBeforeTheFirstFileIsMovedAndAfterEveryOneIsStaged() throws {
        let e = try env(self)
        try e.fill()
        let calls = Calls()
        var stagedCount = 0
        var inPlaceAtSignal = -1
        var migrator = e.migrator(checkpoint: { if case .staged = $0 { stagedCount += 1 } })
        migrator.pointOfNoReturn = {
            calls.bump()
            inPlaceAtSignal = ApplicationSupportPaths.Category.allCases.reduce(0) { $0 + names(e.paths.directory(for: $1)).count }
        }
        XCTAssertEqual(migrator.run().state, .completed)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(stagedCount, 3, "all three were staged by then")
        XCTAssertEqual(inPlaceAtSignal, 0, "and none was in its folder yet")
    }

    func testItIsNotSignalledWhenTheRunStopsBeforeTheMoveOrNeverGetsThere() throws {
        // Cancelled while staging.
        let a = try env(self)
        try a.fill()
        let calls = Calls()
        var seen = 0
        var cancelling = a.migrator(checkpoint: { if case .staged = $0 { seen += 1 } }, isCancelled: { seen >= 1 })
        cancelling.pointOfNoReturn = { calls.bump() }
        XCTAssertEqual(cancelling.run().state, .cancelled)
        // Cancelled at the very last check.
        let b = try env(self)
        try b.fill()
        var staged = 0
        var last = b.migrator(checkpoint: { if case .staged = $0 { staged += 1 } }, isCancelled: { staged == 3 })
        last.pointOfNoReturn = { calls.bump() }
        XCTAssertEqual(last.run().state, .cancelled)
        // Waiting for a confirmation, not enough room, nothing to copy.
        let c = try env(self)
        try c.fill()
        var large = c.migrator(threshold: 1)
        large.pointOfNoReturn = { calls.bump() }
        if case .needsConfirmation = large.run().state {} else { XCTFail("confirmation") }
        var room = c.migrator(space: 1)
        room.pointOfNoReturn = { calls.bump() }
        if case .insufficientSpace = room.run().state {} else { XCTFail("space") }
        let d = try env(self)
        var empty = d.migrator()
        empty.pointOfNoReturn = { calls.bump() }
        _ = empty.run()
        XCTAssertEqual(calls.count, 0)
    }

    func testTheSignalDoesNotChangeWhatIsCopied() throws {
        let a = try env(self)
        try a.fill()
        let b = try env(self)
        try b.fill()
        var withSignal = b.migrator()
        withSignal.pointOfNoReturn = {}
        let r1 = a.migrator().run()
        let r2 = withSignal.run()
        XCTAssertEqual(r1.state, r2.state)
        XCTAssertEqual(r1.entries.map(\.name).sorted().count, r2.entries.count)
    }
}

@MainActor final class PointOfNoReturnSessionTests: XCTestCase {
    private final class Closed { var calls: [Bool] = [] }

    private func session(_ flow: CombinedMigrationCoordinator, closed: Closed = Closed()) -> MigrationSession {
        MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: true) { closed.calls.append($0) }
    }

    func testCancelIsOfferedWhileStagingAndWithdrawnAtThePointOfNoReturn() async throws {
        let e = try env(self)
        try e.fill()
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { return XCTFail("A") }
        let atStaging = expectation(description: "staging")
        let atMerge = expectation(description: "past the point")
        let go1 = DispatchSemaphore(value: 0)
        let go2 = DispatchSemaphore(value: 0)
        var first = true
        var flow = e.coordinator(checkpoint: { point in
            if case .staged = point, first { first = false; atStaging.fulfill(); go1.wait() }
            if case .merged = point, !first { first = true; atMerge.fulfill(); go2.wait() }
        })
        flow.files.pointOfNoReturn = {}           // replaced by the session's own
        let s = session(flow)
        XCTAssertFalse(s.canCancel, "nothing runs yet")
        s.choose(.importNow)
        await fulfillment(of: [atStaging], timeout: 10)
        XCTAssertTrue(s.canCancel)
        XCTAssertFalse(s.isPastPointOfNoReturn)
        go1.signal()
        await fulfillment(of: [atMerge], timeout: 10)
        // Let the signal, queued on the main actor, be applied.
        for _ in 0..<50 where !s.isPastPointOfNoReturn { await Task.yield(); try await Task.sleep(nanoseconds: 10_000_000) }

        XCTAssertTrue(s.isPastPointOfNoReturn)
        XCTAssertFalse(s.canCancel, "Cancel is withdrawn")
        s.cancel()
        XCTAssertFalse(s.isCancelling, "a cancel now does nothing, and does not claim to")
        XCTAssertEqual(s.phase, .running)
        go2.signal()
        await s.waitForWork()
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(result.files?.completed, true, "the copy ran to the end")
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.markerURL.path))
        XCTAssertFalse(s.isPastPointOfNoReturn, "reset with the job")
        XCTAssertFalse(s.canCancel)
    }

    func testACancelAskedJustBeforeTheSignalIsDroppedAndTheCopyCompletes() async throws {
        let e = try env(self)
        try e.fill()
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { return XCTFail("A") }
        let atMerge = expectation(description: "past the point")
        let go = DispatchSemaphore(value: 0)
        // The cancel is asked once the engine has made its last check, so the engine does not see it.
        var held = false
        let flow = e.coordinator(checkpoint: { point in
            if case .merged = point, !held { held = true; atMerge.fulfill(); go.wait() }
        })
        let s = session(flow)
        s.choose(.importNow)
        await fulfillment(of: [atMerge], timeout: 10)
        for _ in 0..<50 where !s.isPastPointOfNoReturn { await Task.yield(); try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(s.isPastPointOfNoReturn)
        s.cancel()
        XCTAssertFalse(s.isCancelling)
        go.signal()
        await s.waitForWork()
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(result.files?.completed, true)
    }

    func testACancelBeforeThePointStillStopsCleanlyAndNeverShowsTheLateMessage() async throws {
        let e = try env(self)
        try e.fill()
        guard case .imported = e.coordinator().preferences.choose(.importNow) else { return XCTFail("A") }
        let atStaging = expectation(description: "staging")
        let go = DispatchSemaphore(value: 0)
        var first = true
        let s = session(e.coordinator(checkpoint: { point in
            if case .staged = point, first { first = false; atStaging.fulfill(); go.wait() }
        }))
        s.choose(.importNow)
        await fulfillment(of: [atStaging], timeout: 10)
        s.cancel()
        XCTAssertTrue(s.isCancelling)
        XCTAssertFalse(s.canCancel, "asked once is enough")
        go.signal()
        await s.waitForWork()
        XCTAssertFalse(s.isPastPointOfNoReturn)
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(result.files?.completed, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.markerURL.path))
    }

    func testTheSignalIsIgnoredOutsideARunAndTheFlagDoesNotLeakIntoTheNextOne() async throws {
        let e = try env(self)
        try e.fill()
        let s = session(e.coordinator())
        XCTAssertFalse(s.isPastPointOfNoReturn)
        XCTAssertFalse(s.canCancel)
        s.choose(.importNow)
        await s.waitForWork()
        XCTAssertFalse(s.isPastPointOfNoReturn, "cleared when the outcome is applied")
    }

    func testTheSynchronousModeAlsoRunsToTheEndAndClearsTheFlag() throws {
        let e = try env(self)
        try e.fill()
        let flow = e.coordinator()
        let s = MigrationSession(prompt: flow.evaluate(), coordinator: flow, defersWork: false) { _ in }
        s.choose(.importNow)
        guard case .finished(let result) = s.phase else { return XCTFail("\(s.phase)") }
        XCTAssertEqual(result.files?.completed, true)
        XCTAssertFalse(s.isPastPointOfNoReturn)
    }

    func testTheWindowSaysItCanNoLongerBeCancelled() throws {
        let view = try source("PageFlow/Views/MigrationView.swift")
        XCTAssertTrue(view.contains("session.isPastPointOfNoReturn"))
        XCTAssertTrue(view.contains("Finishing the import…"))
        XCTAssertTrue(view.contains("can no longer be cancelled"))
        XCTAssertTrue(view.contains("Button(\"Cancel\") { session.cancel() }.disabled(!session.canCancel)"))
        let engine = try source("PageFlow/Migration/AppSupportMigrator.swift")
        let last = try XCTUnwrap(engine.range(of: "if isCancelled() { return cancelled(&report, staging: staging) }\n\n        // Move into place"))
        let signal = try XCTUnwrap(engine.range(of: "pointOfNoReturn()\n        for file in staged"))
        XCTAssertLessThan(last.lowerBound, signal.lowerBound, "the signal comes after the last cancel check, not before it")
    }
}

private extension Mem {
    /// Makes the first write fail, as a refusal or an import that cannot be saved.
    func failOnSetForReentrancy() { failFirstSet = true }
}
