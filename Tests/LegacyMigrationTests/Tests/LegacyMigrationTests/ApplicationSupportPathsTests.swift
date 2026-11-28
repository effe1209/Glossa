import XCTest
@testable import LegacyMigration

// Phase 1 of the Application Support work: where the folders are, and which ones the stores use.
// Every path here is computed from a temporary base. Nothing reads the reader's real Application
// Support, and nothing is created, copied or changed there.

private func repositoryRoot() -> URL { (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() } }
private func source(_ name: String) throws -> String { try String(contentsOf: repositoryRoot().appendingPathComponent(name), encoding: .utf8) }

private func tempBase(_ test: XCTestCase) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-paths-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
}

final class ApplicationSupportPathsTests: XCTestCase {
    func testGlossaPathsSitUnderTheInjectedBase() throws {
        let base = try tempBase(self)
        let paths = ApplicationSupportPaths(base: base)
        XCTAssertEqual(paths.base, base)
        XCTAssertEqual(paths.glossaRoot, base.appendingPathComponent("Glossa", isDirectory: true))
        XCTAssertEqual(paths.recovery, base.appendingPathComponent("Glossa/Recovery", isDirectory: true))
        XCTAssertEqual(paths.attachments, base.appendingPathComponent("Glossa/Attachments", isDirectory: true))
        XCTAssertEqual(paths.epubAnnotations, base.appendingPathComponent("Glossa/EPUB Annotations", isDirectory: true))
    }

    func testPageFlowPathsAreTheOldOnes() throws {
        let base = try tempBase(self)
        let paths = ApplicationSupportPaths(base: base)
        XCTAssertEqual(paths.legacyRoot, base.appendingPathComponent("PageFlow", isDirectory: true))
        XCTAssertEqual(paths.legacyDirectory(for: .recovery), base.appendingPathComponent("PageFlow/Recovery", isDirectory: true))
        XCTAssertEqual(paths.legacyDirectory(for: .attachments), base.appendingPathComponent("PageFlow/Attachments", isDirectory: true))
        XCTAssertEqual(paths.legacyDirectory(for: .epubAnnotations), base.appendingPathComponent("PageFlow/EPUB Annotations", isDirectory: true))
    }

    func testTheThreeCategoriesAreSeparateAndTheTwoRootsDoNotOverlap() throws {
        let paths = ApplicationSupportPaths(base: try tempBase(self))
        let glossa = ApplicationSupportPaths.Category.allCases.map { paths.directory(for: $0).path }
        let legacy = ApplicationSupportPaths.Category.allCases.map { paths.legacyDirectory(for: $0).path }
        XCTAssertEqual(Set(glossa + legacy).count, 6, "six different folders")
        XCTAssertEqual(ApplicationSupportPaths.Category.allCases.map(\.folderName), ["Recovery", "Attachments", "EPUB Annotations"])
        for path in glossa { XCTAssertTrue(path.hasPrefix(paths.glossaRoot.path + "/")); XCTAssertFalse(path.hasPrefix(paths.legacyRoot.path + "/")) }
        for path in legacy { XCTAssertTrue(path.hasPrefix(paths.legacyRoot.path + "/")); XCTAssertFalse(path.hasPrefix(paths.glossaRoot.path + "/")) }
        XCTAssertFalse(paths.glossaRoot.path.hasPrefix(paths.legacyRoot.path + "/"))
        XCTAssertFalse(paths.legacyRoot.path.hasPrefix(paths.glossaRoot.path + "/"))
    }

    func testTheShortNamesAreTheCategoryFolders() throws {
        let paths = ApplicationSupportPaths(base: try tempBase(self))
        XCTAssertEqual(paths.recovery, paths.directory(for: .recovery))
        XCTAssertEqual(paths.attachments, paths.directory(for: .attachments))
        XCTAssertEqual(paths.epubAnnotations, paths.directory(for: .epubAnnotations))
    }

    func testComputingPathsCreatesNothingAndNeverLooksAtPageFlowsFolder() throws {
        let base = try tempBase(self)
        // A PageFlow folder with a file in it, whose bytes must not change.
        let legacy = base.appendingPathComponent("PageFlow/Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let file = legacy.appendingPathComponent("note.json")
        try Data("legacy".utf8).write(to: file)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        let paths = ApplicationSupportPaths(base: base)
        for category in ApplicationSupportPaths.Category.allCases { _ = paths.directory(for: category); _ = paths.legacyDirectory(for: category) }
        _ = paths.glossaRoot; _ = paths.legacyRoot

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), ["PageFlow"], "no Glossa folder appeared")
        XCTAssertEqual(try Data(contentsOf: file), Data("legacy".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date, before)
    }

    func testTheStoresFolderIsGlossasEvenWhenOnlyPageFlowHasData() throws {
        let base = try tempBase(self)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("PageFlow/EPUB Annotations"), withIntermediateDirectories: true)
        let paths = ApplicationSupportPaths(base: base)
        let used = paths.directory(for: .epubAnnotations)
        XCTAssertEqual(used, base.appendingPathComponent("Glossa/EPUB Annotations", isDirectory: true), "no fallback to PageFlow's folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: used.path))
    }

    func testApplicationSupportLocationsFromThePreviousPRAgreeWithThePaths() throws {
        let base = try tempBase(self)
        let paths = ApplicationSupportPaths(base: base)
        XCTAssertEqual(ApplicationSupportLocations.glossa(in: base), paths.glossaRoot)
        XCTAssertEqual(ApplicationSupportLocations.legacy(in: base), paths.legacyRoot)
        XCTAssertEqual(ApplicationSupportLocations.glossaFolderName, ApplicationSupportPaths.glossaFolderName)
        XCTAssertEqual(ApplicationSupportLocations.legacyFolderName, ApplicationSupportPaths.legacyFolderName)
    }

    // MARK: Sandbox

    func testASandboxedBuildUsesItsContainersFolderAndCannotReachPageFlows() throws {
        let container = try tempBase(self).appendingPathComponent("Containers/io.github.effe1209.Glossa/Data/Library/Application Support", isDirectory: true)
        let paths = ApplicationSupportPaths(base: container, legacyIsReachable: false)
        XCTAssertFalse(paths.legacyIsReachable)
        XCTAssertEqual(paths.recovery, container.appendingPathComponent("Glossa/Recovery", isDirectory: true), "the folders are the container's own, not a way around it")
        XCTAssertTrue(paths.attachments.path.hasPrefix(container.path))
    }

    func testCurrentPathsFollowTheSandboxFlagAndTheSystemsFolder() {
        let open = ApplicationSupportPaths.current(isSandboxed: false)
        let sandboxed = ApplicationSupportPaths.current(isSandboxed: true)
        XCTAssertTrue(open.legacyIsReachable)
        XCTAssertFalse(sandboxed.legacyIsReachable)
        XCTAssertEqual(open.base, sandboxed.base, "the base is whatever the system gives this process")
        let system = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        XCTAssertEqual(open.base, system ?? FileManager.default.temporaryDirectory)
        XCTAssertEqual(open.glossaRoot.lastPathComponent, "Glossa")
    }

    func testTheTestProcessIsNotSandboxedSoItsCurrentPathsReachPageFlows() {
        XCTAssertTrue(ApplicationSupportPaths.current().legacyIsReachable)
    }

    // MARK: The stores

    func testTheThreeStoresTakeTheirFolderFromThePathsAndNameNoPageFlowFolder() throws {
        let stores = ["PageFlow/Managers/MarkdownRecoveryStore.swift": "recovery",
                      "PageFlow/Managers/PastedImageStore.swift": "attachments",
                      "PageFlow/Managers/EPUBAnnotationStore.swift": "epubAnnotations"]
        for (file, property) in stores {
            let text = try source(file)
            XCTAssertTrue(text.contains("ApplicationSupportPaths.current().\(property)"), "\(file) does not use the central path")
            XCTAssertFalse(text.contains("applicationSupportDirectory"), "\(file) builds its own Application Support path")
            XCTAssertFalse(text.contains("\"PageFlow/"), "\(file) names a folder under PageFlow's")
            // The attachments store names PageFlow's folder only to recognise the old links in a note
            // (phase 4); the other two never do. No store falls back to PageFlow's folder.
            let allowed = property == "attachments" ? ["legacyDirectory(for: .attachments)", "legacyIsReachable"] : []
            var stripped = text
            for token in allowed { stripped = stripped.replacingOccurrences(of: token, with: "") }
            XCTAssertFalse(stripped.contains("legacyDirectory") || stripped.contains("legacyRoot") || stripped.contains("legacyIsReachable"),
                           "\(file) reaches for PageFlow's folder: no fallback to it")
        }
    }

    func testNothingInTheAppBuildsAnApplicationSupportPathOrReadsPageFlowsFolder() throws {
        let app = repositoryRoot().appendingPathComponent("PageFlow")
        var found: [String] = []
        if let files = FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/PageFlow/Debug/") {
                let text = try String(contentsOf: url, encoding: .utf8)
                let name = url.lastPathComponent
                if name != "ApplicationSupportPaths.swift", text.contains("applicationSupportDirectory") { found.append("\(name): applicationSupportDirectory") }
                // The scanner (phase 2) and the migrator (phase 3) are the only readers of PageFlow's folders, and nothing calls it yet.
                if !["ApplicationSupportPaths.swift", "AppIdentity.swift", "AppSupportScanner.swift", "AppSupportMigrator.swift", "PastedImageStore.swift", "AttachmentLinkRecognizer.swift", "AppSupportOffer.swift"].contains(name),
                   text.contains(".legacyDirectory(") || text.contains(".legacyRoot") { found.append("\(name): legacy path") }
            }
        }
        XCTAssertEqual(found, [], "only the central helper names Application Support, and nothing yet reads PageFlow's folder")
    }

    func testThePathsHelperItselfDoesNothingToTheDisk() throws {
        let paths = try source("PageFlow/Migration/ApplicationSupportPaths.swift")
        XCTAssertFalse(paths.contains("copyItem") || paths.contains("removeItem") || paths.contains("moveItem") || paths.contains("createDirectory"),
                       "the paths do nothing to the disk")
    }
}
