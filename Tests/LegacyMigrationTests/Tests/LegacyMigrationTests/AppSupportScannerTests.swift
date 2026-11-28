import XCTest
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
@testable import LegacyMigration

// The read-only scan of PageFlow's Application Support folders, on temporary folders only. The
// folders hold files made here; nothing of the reader's is read, and nothing is ever written to the
// folder being scanned except by the test that builds it, before the scan.

// MARK: - Fixtures

private func repositoryRoot() -> URL { (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() } }

private struct Fixture {
    let base: URL
    var paths: ApplicationSupportPaths { ApplicationSupportPaths(base: base) }
    var legacy: URL { paths.legacyRoot }
    func folder(_ category: ApplicationSupportPaths.Category) -> URL { paths.legacyDirectory(for: category) }
    func scan(sandboxed: Bool = false) -> AppSupportScanReport {
        AppSupportScanner(paths: ApplicationSupportPaths(base: base, legacyIsReachable: !sandboxed)).scan()
    }
}

private func fixture(_ test: XCTestCase) throws -> Fixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-scan-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: base) }
    return Fixture(base: base)
}

private func makeFolder(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func pngData(width: Int = 4, height: Int = 4) -> Data {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
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

private func recoveryJSON(id: UUID = UUID()) -> (name: String, data: Data) {
    let record = RecoveryRecord(id: id, title: "Draft", originalURL: URL(fileURLWithPath: "/tmp/draft.md"), source: "# Hello",
                                commentBlock: nil, updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    return (id.uuidString + ".json", try! JSONEncoder().encode(record))
}

private func annotationsJSON(identifier: String?, path: String) -> (name: String, data: Data) {
    var object: [String: Any] = ["path": path, "highlights": [], "bookmarks": [], "updatedAt": 7.0e8]
    object["identifier"] = identifier ?? NSNull()
    let name = sha256(Data((identifier.map { "id:\($0)" } ?? "path:\(path)").utf8)) + ".json"
    return (name, try! JSONSerialization.data(withJSONObject: object))
}

private func write(_ data: Data, _ name: String, in folder: URL) throws {
    try makeFolder(folder)
    try data.write(to: folder.appendingPathComponent(name))
}

/// Everything about a folder tree a scan must leave alone: names, sizes, dates, contents.
private func snapshot(_ root: URL) -> [String] {
    var lines: [String] = []
    let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
    if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: []) {
        for case let url as URL in files {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = String(url.path.dropFirst(root.path.count))
            let content = (values?.isDirectory == false && values?.isSymbolicLink == false) ? sha256((try? Data(contentsOf: url)) ?? Data()) : "-"
            lines.append("\(relative)|\(values?.isSymbolicLink ?? false)|\(values?.fileSize ?? -1)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(content)")
        }
    }
    return lines.sorted()
}

// MARK: - Valid files and hashes

final class ScannerValidFilesTests: XCTestCase {
    func testValidFilesOfTheThreeKindsAreReportedWithSizeAndHash() throws {
        let f = try fixture(self)
        let recovery = recoveryJSON()
        let annotations = annotationsJSON(identifier: "urn:uuid:book-1", path: "/books/a.epub")
        let image = pngData()
        try write(recovery.data, recovery.name, in: f.folder(.recovery))
        try write(annotations.data, annotations.name, in: f.folder(.epubAnnotations))
        try write(image, "Pasted image 20240101000000.png", in: f.folder(.attachments))

        let report = f.scan()
        XCTAssertEqual(report.state, .scanned)
        XCTAssertEqual(report.invalidFiles, [])
        XCTAssertEqual(report.skipped, [])
        XCTAssertEqual(report.validFiles.count, 3)
        XCTAssertTrue(report.hasAnythingToCopy)
        let byCategory = Dictionary(uniqueKeysWithValues: report.validFiles.map { ($0.category, $0) })
        XCTAssertEqual(byCategory[.recovery]?.sha256, sha256(recovery.data))
        XCTAssertEqual(byCategory[.recovery]?.size, Int64(recovery.data.count))
        XCTAssertEqual(byCategory[.epubAnnotations]?.sha256, sha256(annotations.data))
        XCTAssertEqual(byCategory[.attachments]?.sha256, sha256(image))
        XCTAssertEqual(report.validBytes, Int64(recovery.data.count + annotations.data.count + image.count))
        XCTAssertEqual(report.report(for: .attachments)?.validBytes, Int64(image.count))
    }

    func testTheHashIsTheWholeFilesEvenWhenItIsLargerThanOneReadChunk() throws {
        let f = try fixture(self)
        var big = pngData()
        big.append(Data(repeating: 0x5A, count: 3 * 1024 * 1024 + 17))   // trailing bytes after a valid PNG
        try write(big, "big.png", in: f.folder(.attachments))
        let file = try XCTUnwrap(f.scan().report(for: .attachments)?.files.first)
        XCTAssertEqual(file.sha256, sha256(big), "streamed in several chunks, equal to the one-shot hash")
        XCTAssertEqual(file.size, Int64(big.count))
    }

    func testKnownVectorHash() throws {
        let f = try fixture(self)
        let note = recoveryJSON()
        try write(note.data, note.name, in: f.folder(.recovery))
        try write(Data("abc".utf8), "abc.png", in: f.folder(.attachments))
        let abc = try XCTUnwrap(f.scan().report(for: .attachments)?.files.first)
        XCTAssertEqual(abc.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAnnotationsFiledByIdentifierOrByPathAreBothValid() throws {
        let f = try fixture(self)
        for sample in [annotationsJSON(identifier: "isbn:1", path: "/b/1.epub"), annotationsJSON(identifier: nil, path: "/b/2.epub")] {
            try write(sample.data, sample.name, in: f.folder(.epubAnnotations))
        }
        // A book with an identifier may still have its older path-keyed file.
        let older = annotationsJSON(identifier: nil, path: "/b/1.epub")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: older.data) as? [String: Any])
        object["identifier"] = "isbn:1"
        try write(try JSONSerialization.data(withJSONObject: object), older.name, in: f.folder(.epubAnnotations))
        XCTAssertEqual(f.scan().validFiles.count, 3)
        XCTAssertEqual(f.scan().invalidFiles.count, 0)
    }

    func testTheReportIsOrderedByName() throws {
        let f = try fixture(self)
        for name in ["c.png", "a.png", "b.png"] { try write(pngData(), name, in: f.folder(.attachments)) }
        XCTAssertEqual(f.scan().report(for: .attachments)?.files.map(\.name), ["a.png", "b.png", "c.png"])
    }
}

// MARK: - Invalid files

final class ScannerInvalidFilesTests: XCTestCase {
    private func only(_ report: AppSupportScanReport, _ category: ApplicationSupportPaths.Category) throws -> AppSupportScannedFile {
        let files = try XCTUnwrap(report.report(for: category)).files
        XCTAssertEqual(files.count, 1)
        return try XCTUnwrap(files.first)
    }

    func testCorruptRecoveryJSONIsInvalidAndKeepsItsHash() throws {
        let f = try fixture(self)
        let bytes = Data("{ not json".utf8)
        try write(bytes, UUID().uuidString + ".json", in: f.folder(.recovery))
        let file = try only(f.scan(), .recovery)
        XCTAssertEqual(file.verdict, .invalid(.notJSON))
        XCTAssertEqual(file.sha256, sha256(bytes))
    }

    func testRecoveryJSONOfTheWrongShapeOrWithTheWrongNameIsInvalid() throws {
        let f = try fixture(self)
        try write(Data(#"{"id": "not-a-uuid"}"#.utf8), UUID().uuidString + ".json", in: f.folder(.recovery))
        XCTAssertEqual(try only(f.scan(), .recovery).verdict, .invalid(.wrongStructure("not a recovery copy")))

        let g = try fixture(self)
        let good = recoveryJSON()
        try write(good.data, UUID().uuidString + ".json", in: g.folder(.recovery))   // another id's name
        XCTAssertEqual(try only(g.scan(), .recovery).verdict, .invalid(.nameDoesNotMatchContent))
    }

    func testAnnotationsThatAreCorruptOfTheWrongShapeOrMisnamedAreInvalid() throws {
        let cases: [(Data, String, AppSupportVerdict)] = [
            (Data("[".utf8), "a.json", .invalid(.notJSON)),
            (Data("[1,2]".utf8), "b.json", .invalid(.wrongStructure("not an object"))),
            (try JSONSerialization.data(withJSONObject: ["path": 1, "highlights": [], "bookmarks": [], "updatedAt": 1]), "c.json", .invalid(.wrongStructure("path"))),
            (try JSONSerialization.data(withJSONObject: ["path": "/x", "highlights": "no", "bookmarks": [], "updatedAt": 1]), "d.json", .invalid(.wrongStructure("highlights"))),
            (try JSONSerialization.data(withJSONObject: ["path": "/x", "highlights": [], "bookmarks": [], "updatedAt": "today"]), "e.json", .invalid(.wrongStructure("updatedAt"))),
            (annotationsJSON(identifier: nil, path: "/x").data, "misnamed.json", .invalid(.nameDoesNotMatchContent)),
        ]
        for (data, name, expected) in cases {
            let f = try fixture(self)
            try write(data, name, in: f.folder(.epubAnnotations))
            XCTAssertEqual(try only(f.scan(), .epubAnnotations).verdict, expected, name)
        }
    }

    func testImagesThatAreCorruptTruncatedOrNotImagesAreInvalid() throws {
        let f = try fixture(self)
        let png = pngData(width: 64, height: 64)
        try write(Data(png.prefix(png.count / 2)), "truncated.png", in: f.folder(.attachments))
        try write(Data("this is text, not a picture".utf8), "text.png", in: f.folder(.attachments))
        try write(Data((0..<512).map { UInt8($0 % 251) }), "noise.png", in: f.folder(.attachments))
        try write(pngData(), "good.png", in: f.folder(.attachments))

        let report = f.scan()
        let attachments = try XCTUnwrap(report.report(for: .attachments))
        XCTAssertEqual(attachments.validFiles.map(\.name), ["good.png"])
        XCTAssertEqual(attachments.invalidFiles.map(\.name), ["noise.png", "text.png", "truncated.png"])
        for file in attachments.invalidFiles {
            guard case .invalid(.notAnImage) = file.verdict else { return XCTFail("\(file.name): \(file.verdict)") }
            XCTAssertNotNil(file.sha256, "an invalid file is still hashed")
        }
    }

    func testAnEmptyFileIsInvalid() throws {
        let f = try fixture(self)
        try write(Data(), "empty.png", in: f.folder(.attachments))
        try write(Data(), UUID().uuidString + ".json", in: f.folder(.recovery))
        XCTAssertEqual(f.scan().invalidFiles.map(\.verdict), [.invalid(.empty), .invalid(.empty)])
    }

    func testAnUnreadableFileIsInvalidAndTheScanGoesOn() throws {
        let f = try fixture(self)
        let locked = f.folder(.attachments).appendingPathComponent("locked.png")
        try write(pngData(), "locked.png", in: f.folder(.attachments))
        try write(pngData(), "ok.png", in: f.folder(.attachments))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let attachments = try XCTUnwrap(f.scan().report(for: .attachments))
        XCTAssertEqual(attachments.validFiles.map(\.name), ["ok.png"])
        let bad = try XCTUnwrap(attachments.invalidFiles.first)
        XCTAssertEqual(bad.name, "locked.png")
        guard case .invalid(.unreadable) = bad.verdict else { return XCTFail("\(bad.verdict)") }
        XCTAssertNil(bad.sha256)
    }

    func testOneBadFileNeverStopsTheScanOfTheOthers() throws {
        let f = try fixture(self)
        let good = recoveryJSON()
        try write(good.data, good.name, in: f.folder(.recovery))
        try write(Data("{".utf8), UUID().uuidString + ".json", in: f.folder(.recovery))
        try write(pngData(), "p.png", in: f.folder(.attachments))
        try write(Data("x".utf8), "q.png", in: f.folder(.attachments))
        let note = annotationsJSON(identifier: nil, path: "/b.epub")
        try write(note.data, note.name, in: f.folder(.epubAnnotations))

        let report = f.scan()
        XCTAssertEqual(report.validFiles.count, 3)
        XCTAssertEqual(report.invalidFiles.count, 2)
    }
}

// MARK: - What is skipped

final class ScannerSkippedEntriesTests: XCTestCase {
    func testSymlinksHiddenFilesAndSubfoldersAreSkippedAndNeverOpened() throws {
        let f = try fixture(self)
        let folder = f.folder(.attachments)
        try write(pngData(), "real.png", in: folder)
        try write(pngData(), ".hidden.png", in: folder)
        try write(Data("x".utf8), ".DS_Store", in: folder)
        try makeFolder(folder.appendingPathComponent("nested"))
        try write(pngData(), "inner.png", in: folder.appendingPathComponent("nested"))
        // A link to a file outside, a link to a file inside, and a dangling link.
        let outside = f.base.appendingPathComponent("outside.png")
        try pngData().write(to: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link-out.png"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link-in.png"), withDestinationURL: folder.appendingPathComponent("real.png"))
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("dangling.png"), withDestinationURL: f.base.appendingPathComponent("nowhere.png"))

        let attachments = try XCTUnwrap(f.scan().report(for: .attachments))
        XCTAssertEqual(attachments.files.map(\.name), ["real.png"], "only the regular, visible file is examined")
        let skipped = Dictionary(uniqueKeysWithValues: attachments.skipped.map { ($0.name, $0.reason) })
        XCTAssertEqual(skipped, [".DS_Store": .hidden, ".hidden.png": .hidden, "dangling.png": .symbolicLink,
                                 "link-in.png": .symbolicLink, "link-out.png": .symbolicLink, "nested": .subfolder])
    }

    func testAHiddenLinkIsReportedAsALink() throws {
        let f = try fixture(self)
        let folder = f.folder(.recovery)
        try makeFolder(folder)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(".link.json"), withDestinationURL: f.base)
        XCTAssertEqual(f.scan().skipped.map(\.reason), [.symbolicLink])
    }

    func testASpecialFileIsSkipped() throws {
        let f = try fixture(self)
        let folder = f.folder(.recovery)
        try makeFolder(folder)
        XCTAssertEqual(mkfifo(folder.appendingPathComponent("pipe.json").path, 0o600), 0)
        let report = f.scan()
        XCTAssertEqual(report.skipped.map(\.reason), [.notARegularFile])
        XCTAssertEqual(report.validFiles + report.invalidFiles, [], "a pipe is never opened: that would block")
    }

    func testACategoryFolderThatIsALinkIsNotFollowed() throws {
        let f = try fixture(self)
        let elsewhere = f.base.appendingPathComponent("elsewhere")
        try write(pngData(), "x.png", in: elsewhere)
        try makeFolder(f.legacy)
        try FileManager.default.createSymbolicLink(at: f.folder(.attachments), withDestinationURL: elsewhere)
        let attachments = try XCTUnwrap(f.scan().report(for: .attachments))
        XCTAssertEqual(attachments.state, .notAFolder)
        XCTAssertEqual(attachments.files, [])
    }

    func testAFileWhereAFolderShouldBeIsNotAFolder() throws {
        let f = try fixture(self)
        try makeFolder(f.legacy)
        try Data("x".utf8).write(to: f.folder(.recovery))
        XCTAssertEqual(f.scan().report(for: .recovery)?.state, .notAFolder)
    }

    func testPageFlowsRootBeingALinkIsNotFollowed() throws {
        let f = try fixture(self)
        let elsewhere = f.base.appendingPathComponent("elsewhere")
        try write(pngData(), "x.png", in: elsewhere.appendingPathComponent("Attachments"))
        try FileManager.default.createSymbolicLink(at: f.legacy, withDestinationURL: elsewhere)
        let report = f.scan()
        XCTAssertEqual(report.state, .rootNotAFolder)
        XCTAssertEqual(report.categories, [])
        XCTAssertFalse(report.hasAnythingToCopy)
    }
}

// MARK: - Missing folders and the sandbox

final class ScannerFoldersAndSandboxTests: XCTestCase {
    func testAMissingPageFlowFolderIsNotAnError() throws {
        let f = try fixture(self)
        let report = f.scan()
        XCTAssertEqual(report.state, .scanned)
        XCTAssertEqual(report.categories.map(\.state), [.missing, .missing, .missing])
        XCTAssertFalse(report.hasAnythingToCopy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.base.path), [], "scanning created nothing")
    }

    func testMissingCategoryFoldersAreReportedOneByOne() throws {
        let f = try fixture(self)
        try makeFolder(f.folder(.recovery))                      // present and empty
        try write(pngData(), "a.png", in: f.folder(.attachments))
        let report = f.scan()
        XCTAssertEqual(report.report(for: .recovery)?.state, .present)
        XCTAssertEqual(report.report(for: .recovery)?.files, [])
        XCTAssertEqual(report.report(for: .attachments)?.state, .present)
        XCTAssertEqual(report.report(for: .epubAnnotations)?.state, .missing)
        XCTAssertEqual(report.validFiles.count, 1)
    }

    func testASandboxedBuildScansNothingEvenWhenTheFolderIsThere() throws {
        let f = try fixture(self)
        try write(pngData(), "a.png", in: f.folder(.attachments))
        let report = f.scan(sandboxed: true)
        XCTAssertEqual(report.state, .legacyUnreachable)
        XCTAssertEqual(report.categories, [])
        XCTAssertFalse(report.hasAnythingToCopy)
        XCTAssertEqual(f.scan(sandboxed: false).validFiles.count, 1, "the same folder is scanned when it is reachable")
    }

    func testCurrentPathsOfASandboxedProcessScanNothing() {
        let scanner = AppSupportScanner(paths: ApplicationSupportPaths.current(isSandboxed: true))
        XCTAssertEqual(scanner.scan().state, .legacyUnreachable)
    }
}

// MARK: - Nothing is written

final class ScannerReadOnlyTests: XCTestCase {
    func testScanningLeavesEveryByteNameAndDateOfTheSourceAsItWas() throws {
        let f = try fixture(self)
        let recovery = recoveryJSON()
        try write(recovery.data, recovery.name, in: f.folder(.recovery))
        try write(Data("{".utf8), UUID().uuidString + ".json", in: f.folder(.recovery))
        try write(pngData(), "a.png", in: f.folder(.attachments))
        try write(Data("junk".utf8), "bad.png", in: f.folder(.attachments))
        try write(pngData(), ".hidden", in: f.folder(.attachments))
        try makeFolder(f.folder(.attachments).appendingPathComponent("sub"))
        try FileManager.default.createSymbolicLink(at: f.folder(.attachments).appendingPathComponent("l"), withDestinationURL: f.base)
        let note = annotationsJSON(identifier: "x", path: "/b.epub")
        try write(note.data, note.name, in: f.folder(.epubAnnotations))

        let before = snapshot(f.base)
        _ = f.scan()
        _ = f.scan()
        XCTAssertEqual(snapshot(f.base), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.paths.glossaRoot.path), "no Glossa folder, no staging, no marker")
    }

    func testTheScannerNamesNoWritingCall() throws {
        let text = try String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow/Migration/AppSupportScanner.swift"), encoding: .utf8)
        // The header comment says what it does not do; look at code lines only.
        let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for call in ["createDirectory", "copyItem", "moveItem", "removeItem", "setAttributes", "createFile", ".write(", "O_WRONLY", "O_RDWR", "O_CREAT",
                     "UserDefaults", "CFPreferences", "trashItem", "createSymbolicLink"] {
            XCTAssertFalse(code.contains(call), "the scanner uses \(call)")
        }
        XCTAssertTrue(code.contains("O_RDONLY | O_NOFOLLOW"))
    }

    func testNothingInTheAppCallsTheScannerYet() throws {
        let app = repositoryRoot().appendingPathComponent("PageFlow")
        var callers: [String] = []
        if let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" && !["AppSupportScanner.swift", "AppSupportMigrator.swift"].contains(url.lastPathComponent) {
                if try String(contentsOf: url, encoding: .utf8).contains("AppSupportScanner") { callers.append(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(callers, [], "no launch hook, no interface, no store uses it in this phase")
    }

    func testTheValidationsMatchTheFieldsTheStoresDeclare() throws {
        // The scanner mirrors the stores' record types (they cannot be built outside the app).
        let recovery = try String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow/Managers/MarkdownRecoveryStore.swift"), encoding: .utf8)
        for field in ["var id: UUID", "var title: String", "var originalURL: URL?", "var source: String", "var commentBlock: String?", "var updatedAt: Date"] {
            XCTAssertTrue(recovery.contains(field), "MarkdownRecoveryStore.Record no longer has `\(field)`: update the scanner")
        }
        let epub = try String(contentsOf: repositoryRoot().appendingPathComponent("PageFlow/Managers/EPUBAnnotationStore.swift"), encoding: .utf8)
        for field in ["var identifier: String?", "var path: String", "var highlights: [EPUBHighlight]", "var bookmarks: [EPUBBookmark]", "var updatedAt: Date"] {
            XCTAssertTrue(epub.contains(field), "EPUBAnnotationStore.Record no longer has `\(field)`: update the scanner")
        }
        XCTAssertTrue(epub.contains("\"id:\\($0)\"") && epub.contains("\"path:\\(path)\""), "the file-name rule changed: update the scanner")
        XCTAssertTrue(recovery.contains("id.uuidString + \".json\""), "the file-name rule changed: update the scanner")
    }
}
