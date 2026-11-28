import XCTest
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import LegacyMigration

// The copy of PageFlow's Application Support files into Glossa's, on temporary folders only. The
// "PageFlow" folder here is built by the test; nothing of the reader's is read, and a test that
// cuts a run short does it with a hook, never by touching anything real.

// MARK: - Fixtures

private func repositoryRoot() -> URL { (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() } }

private struct World {
    let base: URL
    var paths: ApplicationSupportPaths { ApplicationSupportPaths(base: base) }
    func legacy(_ c: ApplicationSupportPaths.Category) -> URL { paths.legacyDirectory(for: c) }
    func glossa(_ c: ApplicationSupportPaths.Category) -> URL { paths.directory(for: c) }
    var markerURL: URL { AppSupportMarker.url(in: paths.glossaRoot) }

    func migrator(sandboxed: Bool = false, space: Int64? = Int64.max / 4, threshold: Int64? = nil,
                  checkpoint: @escaping (AppSupportMigrator.Checkpoint) throws -> Void = { _ in }) -> AppSupportMigrator {
        var m = AppSupportMigrator(paths: ApplicationSupportPaths(base: base, legacyIsReachable: !sandboxed))
        m.availableSpace = { _ in space }
        m.appVersion = "9.9"
        m.checkpoint = checkpoint
        if let threshold { m.largeAttachmentsThreshold = threshold }
        return m
    }
}

private func world(_ test: XCTestCase) throws -> World {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-migrate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    return World(base: base)
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func png(_ side: Int = 4) -> Data {
    let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

private struct RecoveryRecord: Codable {
    var id: UUID
    var title: String
    var originalURL: URL?
    var source: String
    var commentBlock: String?
    var updatedAt: Date
}

private func recovery(_ title: String = "Draft") -> (name: String, data: Data) {
    let id = UUID()
    let record = RecoveryRecord(id: id, title: title, originalURL: nil, source: "# \(title)", commentBlock: nil,
                                updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    return (id.uuidString + ".json", try! JSONEncoder().encode(record))
}

private func annotations(_ path: String) -> (name: String, data: Data) {
    let object: [String: Any] = ["path": path, "highlights": [], "bookmarks": [], "updatedAt": 7.0e8, "identifier": NSNull()]
    return (sha(Data("path:\(path)".utf8)) + ".json", try! JSONSerialization.data(withJSONObject: object))
}

private func put(_ data: Data, _ name: String, in folder: URL) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent(name))
}

/// A PageFlow folder with one valid file of each kind; returns what was written.
@discardableResult
private func standardSource(_ w: World) throws -> (recovery: (name: String, data: Data), image: Data, notes: (name: String, data: Data)) {
    let r = recovery()
    let n = annotations("/books/a.epub")
    let image = png()
    try put(r.data, r.name, in: w.legacy(.recovery))
    try put(image, "Pasted image 1.png", in: w.legacy(.attachments))
    try put(n.data, n.name, in: w.legacy(.epubAnnotations))
    return (r, image, n)
}

private func snapshot(_ root: URL) -> [String] {
    var lines: [String] = []
    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) {
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let content = (values?.isDirectory == false && values?.isSymbolicLink == false) ? sha((try? Data(contentsOf: url)) ?? Data()) : "-"
            lines.append("\(url.path.dropFirst(root.path.count))|\(values?.isSymbolicLink ?? false)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(content)")
        }
    }
    return lines.sorted()
}

private func names(_ url: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }

private func readMarker(_ w: World) throws -> AppSupportMarker {
    try JSONDecoder().decode(AppSupportMarker.self, from: Data(contentsOf: w.markerURL))
}

// MARK: - A complete copy

final class MigratorCopyTests: XCTestCase {
    func testTheThreeKindsAreCopiedByteForByteAndVerified() throws {
        let w = try world(self)
        let s = try standardSource(w)
        let report = w.migrator().run()

        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(report.copied.count, 3)
        XCTAssertEqual(report.identical.count + report.conflicts.count + report.failures.count, 0)
        XCTAssertEqual(try Data(contentsOf: w.glossa(.recovery).appendingPathComponent(s.recovery.name)), s.recovery.data)
        XCTAssertEqual(try Data(contentsOf: w.glossa(.attachments).appendingPathComponent("Pasted image 1.png")), s.image)
        XCTAssertEqual(try Data(contentsOf: w.glossa(.epubAnnotations).appendingPathComponent(s.notes.name)), s.notes.data)
        for entry in report.entries {
            let copy = w.glossa(entry.category).appendingPathComponent(entry.name)
            XCTAssertEqual(sha(try Data(contentsOf: copy)), entry.sha256, "the SHA-256 in the report is the copy's")
        }
        XCTAssertEqual(report.copiedBytes, Int64(s.recovery.data.count + s.image.count + s.notes.data.count))
    }

    func testPageFlowsFolderIsLeftExactlyAsItWasAndNothingIsLeftOver() throws {
        let w = try world(self)
        try standardSource(w)
        try put(Data("{".utf8), UUID().uuidString + ".json", in: w.legacy(.recovery))
        try put(Data("hidden".utf8), ".hidden", in: w.legacy(.attachments))
        try FileManager.default.createSymbolicLink(at: w.legacy(.attachments).appendingPathComponent("link"), withDestinationURL: w.base)
        let before = snapshot(w.paths.legacyRoot)
        XCTAssertEqual(w.migrator().run().state, .completed)
        XCTAssertEqual(snapshot(w.paths.legacyRoot), before, "no byte, name or date of PageFlow's folder changed")
        XCTAssertEqual(names(w.paths.glossaRoot), [".migration-appsupport-v1.json", "Attachments", "EPUB Annotations", "Recovery"],
                       "no staging folder and no temporary file remain")
    }

    func testInvalidAndSkippedFilesAreNotCopiedAndDoNotStopTheRest() throws {
        let w = try world(self)
        try standardSource(w)
        let corrupt = UUID().uuidString + ".json"
        try put(Data("{ nope".utf8), corrupt, in: w.legacy(.recovery))
        try put(Data("not a picture".utf8), "bad.png", in: w.legacy(.attachments))
        try put(png(), ".secret.png", in: w.legacy(.attachments))
        try FileManager.default.createDirectory(at: w.legacy(.attachments).appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: w.legacy(.attachments).appendingPathComponent("lnk.png"), withDestinationURL: w.base)

        let report = w.migrator().run()
        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(report.copied.count, 3)
        XCTAssertEqual(report.invalid.map(\.name).sorted(), [corrupt, "bad.png"].sorted())
        XCTAssertEqual(report.skipped.count, 4 - 1 + 0, "the hidden file, the folder and the link are skipped")   // .secret.png, sub, lnk.png
        XCTAssertEqual(names(w.glossa(.attachments)), ["Pasted image 1.png"])
        XCTAssertEqual(names(w.glossa(.recovery)).count, 1)
    }

    func testTheMarkerRecordsEveryFileTheInvalidOnesAndTheJSONLimit() throws {
        let w = try world(self)
        let s = try standardSource(w)
        try put(Data("{ nope".utf8), UUID().uuidString + ".json", in: w.legacy(.recovery))
        XCTAssertEqual(w.migrator().run().state, .completed)

        let marker = try readMarker(w)
        XCTAssertEqual(marker.version, 1)
        XCTAssertEqual(marker.status, .completed)
        XCTAssertEqual(marker.appVersion, "9.9")
        XCTAssertEqual(marker.source, w.paths.legacyRoot.path)
        XCTAssertEqual(marker.jsonLimitBytes, 64 * 1024 * 1024)
        XCTAssertEqual(marker.files.count, 3)
        XCTAssertEqual(Set(marker.files.map(\.outcome)), ["copied"])
        XCTAssertTrue(marker.files.contains { $0.name == s.recovery.name && $0.sha256 == sha(s.recovery.data) && $0.size == Int64(s.recovery.data.count) })
        XCTAssertEqual(marker.invalid.count, 1)
        XCTAssertEqual(marker.invalid.first?.reason, "not JSON")
        XCTAssertFalse(marker.runId.isEmpty)
    }

    func testTheRecoveryFolderIsPrivate() throws {
        let w = try world(self)
        try standardSource(w)
        _ = w.migrator().run()
        let mode = try FileManager.default.attributesOfItem(atPath: w.glossa(.recovery).path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testAJSONFileOverTheLimitIsNotCopiedAndIsFlagged() throws {
        let w = try world(self)
        try standardSource(w)
        try FileManager.default.createDirectory(at: w.legacy(.recovery), withIntermediateDirectories: true)
        let big = w.legacy(.recovery).appendingPathComponent(UUID().uuidString + ".json")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(AppSupportScanner.jsonLimit) + 1)    // sparse: no real disk used
        try handle.close()

        let report = w.migrator().run()
        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(report.overJSONLimit.map(\.name), [big.lastPathComponent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.glossa(.recovery).appendingPathComponent(big.lastPathComponent).path))
        let marker = try readMarker(w)
        XCTAssertEqual(marker.invalid.first?.reason, "over the 64 MiB limit for JSON files")
    }
}

// MARK: - Destinations and conflicts

final class MigratorDestinationTests: XCTestCase {
    func testAnEmptyExistingDestinationIsFilled() throws {
        let w = try world(self)
        try standardSource(w)
        for c in ApplicationSupportPaths.Category.allCases { try FileManager.default.createDirectory(at: w.glossa(c), withIntermediateDirectories: true) }
        XCTAssertEqual(w.migrator().run().copied.count, 3)
    }

    func testAnIdenticalFileInGlossaIsCountedAndNotTouched() throws {
        let w = try world(self)
        let s = try standardSource(w)
        try put(s.image, "Pasted image 1.png", in: w.glossa(.attachments))
        let target = w.glossa(.attachments).appendingPathComponent("Pasted image 1.png")
        let before = try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date

        let report = w.migrator().run()
        XCTAssertEqual(report.state, .completed)
        XCTAssertEqual(report.identical.map(\.name), ["Pasted image 1.png"])
        XCTAssertEqual(report.copied.count, 2)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.modificationDate] as? Date, before)
        XCTAssertEqual(report.identicalBytes, Int64(s.image.count))
    }

    func testAConflictIsWonByGlossaAndNothingIsOverwritten() throws {
        let w = try world(self)
        let s = try standardSource(w)
        let glossasOwn = Data("Glossa wrote this one".utf8)
        try put(glossasOwn, s.recovery.name, in: w.glossa(.recovery))
        try put(Data("unrelated".utf8), "keep-me.json", in: w.glossa(.recovery))

        let report = w.migrator().run()
        XCTAssertEqual(report.state, .completed, "a conflict is accounted for, not a failure")
        XCTAssertEqual(report.conflicts.map(\.name), [s.recovery.name])
        XCTAssertEqual(try Data(contentsOf: w.glossa(.recovery).appendingPathComponent(s.recovery.name)), glossasOwn, "Glossa's file is untouched")
        XCTAssertEqual(try Data(contentsOf: w.glossa(.recovery).appendingPathComponent("keep-me.json")), Data("unrelated".utf8))
        XCTAssertEqual(try Data(contentsOf: w.legacy(.recovery).appendingPathComponent(s.recovery.name)), s.recovery.data, "and PageFlow's is too")
        XCTAssertEqual(report.conflictBytes, Int64(s.recovery.data.count))
        XCTAssertEqual(try readMarker(w).files.first { $0.name == s.recovery.name }?.outcome, "conflict")
        XCTAssertEqual(names(w.paths.glossaRoot).filter { $0.hasPrefix(".import-staging") }, [])
    }

    func testSomethingThatIsNotAFileAtTheNameIsAConflictToo() throws {
        let w = try world(self)
        let s = try standardSource(w)
        try FileManager.default.createDirectory(at: w.glossa(.epubAnnotations).appendingPathComponent(s.notes.name), withIntermediateDirectories: true)
        let report = w.migrator().run()
        XCTAssertEqual(report.conflicts.map(\.name), [s.notes.name])
        XCTAssertEqual(report.state, .completed)
    }

    func testAnExistingGlossaFolderWithOtherDataIsKept() throws {
        let w = try world(self)
        try standardSource(w)
        try put(Data("a".utf8), "mine.png", in: w.glossa(.attachments))
        try put(Data("b".utf8), "stray.txt", in: w.paths.glossaRoot)
        XCTAssertEqual(w.migrator().run().state, .completed)
        XCTAssertEqual(names(w.glossa(.attachments)), ["Pasted image 1.png", "mine.png"])
        XCTAssertEqual(try Data(contentsOf: w.paths.glossaRoot.appendingPathComponent("stray.txt")), Data("b".utf8))
    }
}

// MARK: - Interruption, idempotence, the marker

final class MigratorInterruptionTests: XCTestCase {
    func testTheMarkerIsTheLastThingWritten() throws {
        let w = try world(self)
        try standardSource(w)
        var markerSeen: [Bool] = []
        let report = w.migrator(checkpoint: { _ in markerSeen.append(FileManager.default.fileExists(atPath: w.markerURL.path)) }).run()
        XCTAssertEqual(report.state, .completed)
        XCTAssertFalse(markerSeen.isEmpty)
        XCTAssertFalse(markerSeen.contains(true), "no marker at any checkpoint, the last one (before the marker) included")
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.markerURL.path))
    }

    func testACutOffDuringStagingLeavesStagingAndNoMarkerAndIsOfferedAgain() throws {
        let w = try world(self)
        let s = try standardSource(w)
        let before = snapshot(w.paths.legacyRoot)
        var staged = 0
        let report = w.migrator(checkpoint: { point in
            if case .staged = point { staged += 1; if staged == 2 { throw AppSupportMigrator.Interrupted() } }
        }).run()

        XCTAssertEqual(report.state, .failed("interrupted"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.markerURL.path))
        guard case .interrupted(let folders) = w.migrator().status() else { return XCTFail("\(w.migrator().status())") }
        XCTAssertEqual(folders.count, 1)
        XCTAssertTrue(folders[0].hasPrefix(".import-staging-"))
        XCTAssertEqual(names(w.glossa(.recovery)), [], "nothing reached its folder")
        XCTAssertEqual(snapshot(w.paths.legacyRoot), before)

        // The reader chooses again: the old staging goes, the copy is made, the marker comes last.
        let again = w.migrator().run()
        XCTAssertEqual(again.state, .completed)
        XCTAssertEqual(again.copied.count, 3)
        XCTAssertEqual(try Data(contentsOf: w.glossa(.recovery).appendingPathComponent(s.recovery.name)), s.recovery.data)
        XCTAssertEqual(names(w.paths.glossaRoot).filter { $0.hasPrefix(".import-staging") }, [])
        guard case .completed = w.migrator().status() else { return XCTFail("not completed") }
    }

    func testNothingResumesByItself() throws {
        let w = try world(self)
        try standardSource(w)
        _ = w.migrator(checkpoint: { if case .staged = $0 { throw AppSupportMigrator.Interrupted() } }).run()
        let leftover = snapshot(w.paths.glossaRoot)
        // Asking for the status, as a launch would, changes nothing.
        _ = w.migrator().status()
        _ = w.migrator().status()
        XCTAssertEqual(snapshot(w.paths.glossaRoot), leftover)
        guard case .interrupted = w.migrator().status() else { return XCTFail("should still be interrupted") }
    }

    func testACutOffAfterSomeFilesWereMovedIsCompletedLaterWithThoseAsIdentical() throws {
        let w = try world(self)
        try standardSource(w)
        var merged = 0
        let first = w.migrator(checkpoint: { point in
            if case .merged = point { merged += 1; if merged == 1 { throw AppSupportMigrator.Interrupted() } }
        }).run()
        XCTAssertEqual(first.state, .failed("interrupted"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.markerURL.path))

        let second = w.migrator().run()
        XCTAssertEqual(second.state, .completed)
        XCTAssertEqual(second.identical.count, 1, "the file already moved is identical, not duplicated")
        XCTAssertEqual(second.copied.count, 2)
    }

    func testACutOffJustBeforeTheMarkerLeavesNoMarker() throws {
        let w = try world(self)
        try standardSource(w)
        let report = w.migrator(checkpoint: { if $0 == .beforeMarker { throw AppSupportMigrator.Interrupted() } }).run()
        XCTAssertEqual(report.state, .failed("interrupted"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.markerURL.path), "all the files are in place and it is still not complete")
        guard case .interrupted = w.migrator().status() else { return XCTFail("a run without a marker is not complete") }
        let second = w.migrator().run()
        XCTAssertEqual(second.state, .completed)
        XCTAssertEqual(second.identical.count, 3)
    }

    func testRunningAgainAfterCompletionDoesNothing() throws {
        let w = try world(self)
        try standardSource(w)
        XCTAssertEqual(w.migrator().run().state, .completed)
        let after = snapshot(w.paths.glossaRoot)
        XCTAssertEqual(w.migrator().run().state, .alreadyCompleted)
        XCTAssertEqual(w.migrator().run().state, .alreadyCompleted)
        XCTAssertEqual(snapshot(w.paths.glossaRoot), after, "no duplicate, no rewrite, not even the marker")
        guard case .completed(let marker) = w.migrator().status() else { return XCTFail() }
        XCTAssertEqual(marker.files.count, 3)
    }

    func testARecoveryFileRemovedLaterIsNotBroughtBackByARerun() throws {
        let w = try world(self)
        let s = try standardSource(w)
        XCTAssertEqual(w.migrator().run().state, .completed)
        try FileManager.default.removeItem(at: w.glossa(.recovery).appendingPathComponent(s.recovery.name))   // the note was saved and its copy dropped
        XCTAssertEqual(w.migrator().run().state, .alreadyCompleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.glossa(.recovery).appendingPathComponent(s.recovery.name).path))
    }

    func testAMarkerThatIsNotValidIsNeverOverwritten() throws {
        let w = try world(self)
        try standardSource(w)
        try FileManager.default.createDirectory(at: w.paths.glossaRoot, withIntermediateDirectories: true)
        try Data("not a marker".utf8).write(to: w.markerURL)
        XCTAssertEqual(w.migrator().status(), .markerInvalid)
        XCTAssertEqual(w.migrator().run().state, .markerInvalid)
        XCTAssertEqual(try Data(contentsOf: w.markerURL), Data("not a marker".utf8))
        XCTAssertEqual(names(w.paths.glossaRoot), [".migration-appsupport-v1.json"], "nothing else was written")

        // A marker of a version this one does not know is not valid either.
        let valid = try { () -> Data in
            var marker = AppSupportMarker(version: 99, status: .completed, completedAt: "", appVersion: "", runId: "", source: "", jsonLimitBytes: 0,
                                          files: [], invalid: [], skippedCount: 0)
            marker.version = 99
            return try JSONEncoder().encode(marker)
        }()
        try valid.write(to: w.markerURL)
        XCTAssertEqual(w.migrator().run().state, .markerInvalid)
    }

    func testAFileThatChangedAfterTheScanIsNotCopiedAndThereIsNoMarker() throws {
        let w = try world(self)
        let s = try standardSource(w)
        var changed = false
        let report = w.migrator(checkpoint: { point in
            guard point == .stagingCreated, !changed else { return }
            changed = true
            try Data("PageFlow rewrote it".utf8).write(to: w.legacy(.recovery).appendingPathComponent(s.recovery.name))
        }).run()

        XCTAssertEqual(report.state, .incomplete)
        XCTAssertEqual(report.failures.map(\.name), [s.recovery.name])
        XCTAssertEqual(report.copied.count, 2, "the others were verified and moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.markerURL.path), "not complete, so no marker")
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.glossa(.recovery).appendingPathComponent(s.recovery.name).path))
        XCTAssertEqual(names(w.paths.glossaRoot).filter { $0.hasPrefix(".import-staging") }, [], "our staging is removed")
        // The offer comes back and the next run, with the file now stable, completes.
        XCTAssertEqual(w.migrator().run().state, .completed)
    }

    func testAStrayStagingLinkIsNotFollowedOrRemoved() throws {
        let w = try world(self)
        try standardSource(w)
        let outside = w.base.appendingPathComponent("outside")
        try put(Data("precious".utf8), "file", in: outside)
        try FileManager.default.createDirectory(at: w.paths.glossaRoot, withIntermediateDirectories: true)
        let link = w.paths.glossaRoot.appendingPathComponent(".import-staging-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertEqual(w.migrator().status(), .notStarted, "a link is not a staging folder")
        XCTAssertEqual(w.migrator().run().state, .completed)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("precious".utf8))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
    }
}

// MARK: - Nothing to do, space, confirmation, sandbox

final class MigratorPreconditionTests: XCTestCase {
    func testNothingSoundMeansNothingIsWrittenAndNoMarker() throws {
        let w = try world(self)
        XCTAssertEqual(w.migrator().run().state, .nothingToCopy, "no PageFlow folder")
        XCTAssertEqual(w.migrator().status(), .notStarted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.paths.glossaRoot.path), "no Glossa folder was made for nothing")
        try put(Data("{".utf8), UUID().uuidString + ".json", in: w.legacy(.recovery))
        let report = w.migrator().run()
        XCTAssertEqual(report.state, .completed, "only a permanently invalid file: concluded, and recorded")
        XCTAssertEqual(report.invalid.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: w.markerURL.path))
    }

    func testNotEnoughRoomWritesNothing() throws {
        let w = try world(self)
        let s = try standardSource(w)
        let size = Int64(s.recovery.data.count + s.image.count + s.notes.data.count)
        let required = size + size / 10 + AppSupportMigrator.spaceMargin
        let short = w.migrator(space: required - 1).run()
        XCTAssertEqual(short.state, .insufficientSpace(required: required, available: required - 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.paths.glossaRoot.path))
        XCTAssertEqual(w.migrator(space: nil).run().state, .insufficientSpace(required: required, available: nil), "unknown room is not assumed")
        XCTAssertEqual(w.migrator(space: required).run().state, .completed, "exactly enough is enough")
    }

    func testTheRealVolumeQueryAnswers() throws {
        XCTAssertNotNil(AppSupportMigrator.systemAvailableSpace(FileManager.default.temporaryDirectory))
    }

    func testAttachmentsOverTheThresholdWaitForAConfirmation() throws {
        let w = try world(self)
        let s = try standardSource(w)
        let threshold = Int64(s.image.count) - 1
        let waiting = w.migrator(threshold: threshold).run()
        XCTAssertEqual(waiting.state, .needsConfirmation(attachmentBytes: Int64(s.image.count)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.paths.glossaRoot.path), "nothing is written before the confirmation")
        XCTAssertEqual(w.migrator(threshold: threshold).run(confirmLargeAttachments: true).state, .completed)
    }

    func testAttachmentsAtTheThresholdNeedNoConfirmation() throws {
        let w = try world(self)
        let s = try standardSource(w)
        XCTAssertEqual(w.migrator(threshold: Int64(s.image.count)).run().state, .completed)
    }

    func testTheThresholdIs500MiBAndCountsOnlyAttachments() throws {
        XCTAssertEqual(AppSupportMigrator.defaultLargeAttachmentsThreshold, 500 * 1024 * 1024)
        let w = try world(self)
        let s = try standardSource(w)
        // A threshold below the recovery and notes files but above the image: only attachments count.
        XCTAssertEqual(w.migrator(threshold: Int64(s.image.count) + 1).run().state, .completed)
    }

    func testASandboxedBuildDoesNothing() throws {
        let w = try world(self)
        try standardSource(w)
        let migrator = w.migrator(sandboxed: true)
        XCTAssertEqual(migrator.status(), .legacyUnreachable)
        XCTAssertEqual(migrator.run().state, .legacyUnreachable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.paths.glossaRoot.path))
    }

    func testAnAlreadyCompletedMigrationIsReportedBeforeAnythingIsScanned() throws {
        let w = try world(self)
        try standardSource(w)
        _ = w.migrator().run()
        // Even a PageFlow folder that would now be unreadable is not looked at again.
        try FileManager.default.removeItem(at: w.paths.legacyRoot)
        XCTAssertEqual(w.migrator().run().state, .alreadyCompleted)
    }
}

// MARK: - What the code may and may not do

final class MigratorCodeTests: XCTestCase {
    private func code() throws -> String {
        let text = try String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow/Migration/AppSupportMigrator.swift"), encoding: .utf8)
        return text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    func testOnlyOurOwnStagingAndStagedFilesAreEverRemoved() throws {
        let lines = try code().components(separatedBy: "\n").filter { $0.contains("removeItem(") }
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertTrue(["staging", "staged"].contains { line.contains($0) } || line.contains("paths.glossaRoot.appendingPathComponent(name)"),
                          "removes something else: \(line)")
            XCTAssertFalse(line.contains("legacy") || line.contains("source"), "removes from PageFlow's side: \(line)")
        }
    }

    func testTheOnlyThingReadFromPageFlowIsCopiedAndNothingIsMovedFromIt() throws {
        let text = try code()
        XCTAssertEqual(text.components(separatedBy: "copyItem(").count - 1, 1)
        XCTAssertTrue(text.contains("copyItem(at: source, to: target)"))
        let moves = text.components(separatedBy: "\n").filter { $0.contains("fileManager.moveItem(") }
        XCTAssertEqual(moves.count, 1)
        XCTAssertTrue(moves[0].contains("at: staged"), "a move starts from our staging only")
        for forbidden in ["setAttributes", "trashItem", "createSymbolicLink", "linkItem", "UserDefaults", "CFPreferences", "replaceItem"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testTheMigratorRunsOnlyFromTheCombinedCoordinator() throws {
        let app = repositoryRoot().appendingPathComponent("PageFlow")
        var runners: [String] = []
        var mentions: Set<String> = []
        if let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "AppSupportMigrator.swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                if text.contains("AppSupportMigrator") { mentions.insert(url.lastPathComponent) }
                if text.contains("migrator.run(confirmLargeAttachments") { runners.append(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(runners, ["CombinedMigrationCoordinator.swift"], "nothing else copies files")
        // The files that name the type: the coordinator, the presenter that builds it, and a comment in the offer.
        XCTAssertEqual(mentions, ["CombinedMigrationCoordinator.swift", "MigrationPresenter.swift", "AppSupportOffer.swift"])
    }

    func testNoStoreRunsTheMigratorOrTheScanner() throws {
        for file in ["MarkdownRecoveryStore", "PastedImageStore", "EPUBAnnotationStore"] {
            let text = try String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow/Managers/\(file).swift"), encoding: .utf8)
            XCTAssertFalse(text.contains("AppSupportMigrator") || text.contains("AppSupportScanner"), "\(file) must not migrate by itself")
        }
    }
}
