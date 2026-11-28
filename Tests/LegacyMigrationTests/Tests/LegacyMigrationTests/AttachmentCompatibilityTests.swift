import XCTest
import CryptoKit
@testable import LegacyMigration

// Phase 4: notes written before Glossa link to images in PageFlow's attachments folder; the files
// have since been copied to Glossa's. Both folders are recognised, the links are never rewritten, and
// nothing is read through from PageFlow. Temporary folders only; the real adoption in the store needs
// AppKit, so what it relies on is tested here and its wiring is checked in the source.

private func repositoryRoot() -> URL { (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() } }
private func source(_ name: String) throws -> String { try String(contentsOf: repositoryRoot().appendingPathComponent(name), encoding: .utf8) }
private func codeLines(_ name: String) throws -> [String] {
    try source(name).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
}
private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private func tempBase(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-attach-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

private func put(_ data: Data, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

final class AttachmentLinkRecognizerTests: XCTestCase {
    func testBothFoldersAreRecognised() throws {
        let paths = ApplicationSupportPaths(base: try tempBase(self))
        let recognizer = AttachmentLinkRecognizer(paths: paths)
        XCTAssertEqual(recognizer.folders, [paths.attachments, paths.legacyDirectory(for: .attachments)], "Glossa's first")
        XCTAssertTrue(recognizer.recognizes(paths.attachments.appendingPathComponent("Pasted image 1.png")))
        XCTAssertTrue(recognizer.recognizes(paths.legacyDirectory(for: .attachments).appendingPathComponent("Pasted image 1.png")))
    }

    func testOtherPlacesAreNotRecognised() throws {
        let paths = ApplicationSupportPaths(base: try tempBase(self))
        let recognizer = AttachmentLinkRecognizer(paths: paths)
        let attachments = paths.attachments
        let legacy = paths.legacyDirectory(for: .attachments)
        for other in [paths.base.appendingPathComponent("Documents/pic.png"),
                      paths.recovery.appendingPathComponent("x.png"),
                      paths.legacyDirectory(for: .recovery).appendingPathComponent("x.png"),
                      paths.legacyRoot.appendingPathComponent("x.png"),
                      paths.base.appendingPathComponent("Glossa/Attachments-old/x.png"),
                      paths.base.appendingPathComponent("PageFlow/Attachments2/x.png"),
                      attachments, legacy,                       // the folders themselves
                      URL(fileURLWithPath: "/tmp/pic.png")] {
            XCTAssertFalse(recognizer.recognizes(other), other.path)
        }
    }

    func testDotDotCannotLeadOutOfARecognisedFolderOrIntoOne() throws {
        let paths = ApplicationSupportPaths(base: try tempBase(self))
        let recognizer = AttachmentLinkRecognizer(paths: paths)
        XCTAssertFalse(recognizer.recognizes(URL(fileURLWithPath: paths.legacyDirectory(for: .attachments).path + "/../../Secrets/key.png")))
        XCTAssertFalse(recognizer.recognizes(URL(fileURLWithPath: paths.attachments.path + "/../Recovery/x.png")))
        XCTAssertTrue(recognizer.recognizes(URL(fileURLWithPath: paths.base.path + "/Elsewhere/../PageFlow/Attachments/x.png")), "the same file by another route")
    }

    func testASandboxedBuildRecognisesOnlyItsOwnFolder() throws {
        let paths = ApplicationSupportPaths(base: try tempBase(self), legacyIsReachable: false)
        let recognizer = AttachmentLinkRecognizer(paths: paths)
        XCTAssertEqual(recognizer.folders, [paths.attachments])
        XCTAssertFalse(recognizer.recognizes(paths.legacyDirectory(for: .attachments).appendingPathComponent("x.png")))
    }

    func testOnlyAPlainFileThatIsThereCanBeAdopted() throws {
        let base = try tempBase(self)
        let paths = ApplicationSupportPaths(base: base)
        let recognizer = AttachmentLinkRecognizer(paths: paths)
        for folder in [paths.attachments, paths.legacyDirectory(for: .attachments)] {
            let real = folder.appendingPathComponent("real.png")
            try put(Data("png".utf8), real)
            XCTAssertTrue(recognizer.canAdopt(real), "a plain file in \(folder.deletingLastPathComponent().lastPathComponent)")
            XCTAssertFalse(recognizer.canAdopt(folder.appendingPathComponent("missing.png")), "a link to a file that is gone")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("dir.png"), withIntermediateDirectories: true)
            XCTAssertFalse(recognizer.canAdopt(folder.appendingPathComponent("dir.png")), "a folder")
            let outside = base.appendingPathComponent("outside.png")
            try put(Data("secret".utf8), outside)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("to-outside.png"), withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("to-inside.png"), withDestinationURL: real)
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("dangling.png"), withDestinationURL: base.appendingPathComponent("nowhere"))
            for link in ["to-outside.png", "to-inside.png", "dangling.png"] {
                XCTAssertFalse(recognizer.canAdopt(folder.appendingPathComponent(link)), "a symbolic link (\(link)) is never adopted")
            }
        }
        XCTAssertFalse(recognizer.canAdopt(base.appendingPathComponent("outside.png")), "a plain file in the wrong place")
    }
}

final class MigratedAttachmentsStayUsableTests: XCTestCase {
    func testALinkToPageFlowsFolderStillWorksAfterTheCopyAndIsNeverRewritten() throws {
        let base = try tempBase(self)
        let paths = ApplicationSupportPaths(base: base)
        let image = TestImages.png()
        let legacyFile = paths.legacyDirectory(for: .attachments).appendingPathComponent("Pasted image 20240101000000.png")
        try put(image, legacyFile)
        // A saved note that still holds the absolute link PageFlow wrote.
        let note = "# Note\n\n![Pasted image](<\(legacyFile.path)>)\n"
        let before = note

        var migrator = AppSupportMigrator(paths: paths)
        migrator.availableSpace = { _ in Int64.max / 4 }
        XCTAssertEqual(migrator.run().state, .completed)

        let recognizer = AttachmentLinkRecognizer(paths: paths)
        XCTAssertEqual(note, before, "the link is not touched")
        XCTAssertTrue(recognizer.canAdopt(legacyFile), "PageFlow's file is still there and its link is still recognised")
        XCTAssertEqual(sha(try Data(contentsOf: legacyFile)), sha(image), "and unchanged")
        let migrated = paths.attachments.appendingPathComponent(legacyFile.lastPathComponent)
        XCTAssertTrue(recognizer.canAdopt(migrated), "the copy is recognised too")
        XCTAssertEqual(try Data(contentsOf: migrated), image)
    }

    func testAnImageThatWasNeverCopiedIsStillRecognisedThroughItsOwnLink() throws {
        // A link names one file: if the migration skipped it (or was never run), the note's own link still decides.
        let paths = ApplicationSupportPaths(base: try tempBase(self))
        let file = paths.legacyDirectory(for: .attachments).appendingPathComponent("a.png")
        try put(Data("x".utf8), file)
        XCTAssertTrue(AttachmentLinkRecognizer(paths: paths).canAdopt(file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.attachments.path), "recognising copied nothing")
    }

    func testAFileOnlyGlossaHasIsNotConfusedWithAMissingLegacyOne() throws {
        // A conflict left Glossa's own file under the same name; a link to PageFlow's path whose file is gone is just missing.
        let paths = ApplicationSupportPaths(base: try tempBase(self))
        try put(Data("glossa's".utf8), paths.attachments.appendingPathComponent("same.png"))
        let recognizer = AttachmentLinkRecognizer(paths: paths)
        XCTAssertFalse(recognizer.canAdopt(paths.legacyDirectory(for: .attachments).appendingPathComponent("same.png")), "no substitution of one file for another")
        XCTAssertTrue(recognizer.canAdopt(paths.attachments.appendingPathComponent("same.png")))
    }

    func testRecognisingJudgesAPathAndReadsNoFolderAndWritesNothing() throws {
        let text = try codeLines("Glossa/Migration/AttachmentLinkRecognizer.swift").joined(separator: "\n")
        for call in ["contentsOfDirectory", "enumerator", "Data(contentsOf", "copyItem", "moveItem", "removeItem", "createDirectory", ".write(",
                     "createFile", "UserDefaults", "FileHandle"] {
            XCTAssertFalse(text.contains(call), "the recogniser uses \(call)")
        }
        XCTAssertTrue(text.contains("lstat("), "a link is judged as a link, not followed")
    }
}

private enum TestImages {
    static func png() -> Data {
        // 1x1 transparent PNG.
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
    }
}

final class AdoptionWiringTests: XCTestCase {
    func testAdoptFallbackImagesRecognisesBothFoldersThroughTheRecogniser() throws {
        let text = try source("Glossa/Managers/PastedImageStore.swift")
        XCTAssertTrue(text.contains("attachmentLinks.canAdopt(file)"))
        XCTAssertFalse(text.contains("hasPrefix(prefix)"), "the old single-prefix test is gone")
        XCTAssertTrue(text.contains("AttachmentLinkRecognizer(folders: [fallbackFolder] + (legacyFallbackFolder.map { [$0] } ?? []))"))
        XCTAssertTrue(text.contains("legacyFallbackFolder: URL? = PastedImageStore.legacyFallbackAttachmentsFolder"))
    }

    func testPageFlowsFolderIsOnlyRecognisedNeverSavedIntoOrChanged() throws {
        let lines = try codeLines("Glossa/Managers/PastedImageStore.swift")
        let legacyUses = lines.filter { $0.contains("legacy") || $0.contains("Legacy") }
        // The parameter, its default, the recogniser and the static that names the folder: nothing else.
        XCTAssertEqual(legacyUses.count, 4, legacyUses.joined(separator: "\n"))
        for line in lines where line.contains("write(") || line.contains("copyItem") || line.contains("removeItem") || line.contains("moveItem") {
            XCTAssertFalse(line.lowercased().contains("legacy"), "writes to or changes PageFlow's side: \(line)")
        }
        // Nothing is saved to the folder the link names: new images go to the note's folder or Glossa's fallback.
        XCTAssertTrue(lines.contains { $0.contains("write(data, named: name, into: fallbackFolder)") })
    }

    func testAdoptionCopiesAndKeepsTheOriginalWithoutOverwriting() throws {
        let text = try source("Glossa/Managers/PastedImageStore.swift")
        let start = try XCTUnwrap(text.range(of: "func adoptFallbackImages"))
        let end = try XCTUnwrap(text.range(of: "private static let imageLinkPattern", range: start.upperBound..<text.endIndex))
        let body = String(text[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(body.contains("removeItem") || body.contains("moveItem"), "the original stays where it is")
        XCTAssertTrue(body.contains("write(data, named: file.lastPathComponent, into: attachments)"))
        XCTAssertTrue(text.contains("firstFreeName"), "a name that is taken gets a number, never a replacement")
        XCTAssertTrue(body.contains("// Keep original resources"), "the links are changed by the document only after it has saved")
    }

    func testThePasteStoreStillSavesNewImagesOnlyUnderGlossa() throws {
        let text = try source("Glossa/Managers/PastedImageStore.swift")
        XCTAssertTrue(text.contains("ApplicationSupportPaths.current().attachments"))
        XCTAssertFalse(text.contains("\"PageFlow/"))
    }
}

final class EPUBAnnotationsUseGlossasFolderTests: XCTestCase {
    func testTheStoreTakesItsFolderFromTheCentralPathsAndHasNoMigrationOfItsOwn() throws {
        let text = try source("Glossa/Managers/EPUBAnnotationStore.swift")
        XCTAssertTrue(text.contains("ApplicationSupportPaths.current().epubAnnotations"))
        let code = try codeLines("Glossa/Managers/EPUBAnnotationStore.swift").joined(separator: "\n")
        for word in ["legacy", "Legacy", "AppSupportMigrator", "AppSupportScanner", "migrat", "Migrat", "PageFlow/", "applicationSupportDirectory"] {
            XCTAssertFalse(code.contains(word), "EPUBAnnotationStore mentions \(word): a second migration or a path of its own")
        }
    }

    func testTheFolderNameIsWrittenOnceInTheWholeApp() throws {
        var literals: [String] = []
        let app = repositoryRoot().appendingPathComponent("Glossa")
        if let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" {
                let code = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                if code.contains("\"EPUB Annotations\"") { literals.append(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(literals, ["ApplicationSupportPaths.swift"], "every use goes through the central paths")
    }

    func testTheTestHostStillUsesATemporaryFolder() throws {
        let text = try source("Glossa/Managers/EPUBAnnotationStore.swift")
        XCTAssertTrue(text.contains("TestEnvironment.isRunningTests"))
        XCTAssertTrue(text.contains("temporaryDirectory.appendingPathComponent(\"PageFlow-EPUB-Annotations-"))
    }
}
