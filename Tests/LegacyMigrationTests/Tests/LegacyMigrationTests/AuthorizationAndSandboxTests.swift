import XCTest
@testable import LegacyMigration

// The sandboxed builds, the message when importing is not available, and the list of permissions
// to allow again. In-memory destinations, a UserDefaults suite in a temporary folder, or source
// scans; nothing reads or writes the reader's real preferences, and no panel is ever shown.

// MARK: - Helpers

private final class Memory: MigrationDestination {
    var store: [String: Any] = [:]
    var sets = 0
    var failOnSet: Int?
    func value(forKey key: String) -> Any? { store[key] }
    func set(_ value: Any, forKey key: String) throws {
        sets += 1
        if let failOnSet, sets == failOnSet { throw LegacyMigrator.Failure(reason: "disk full") }
        store[key] = value
    }
    func remove(forKey key: String) throws { store[key] = nil }
}

private final class Reads: LegacyPreferencesSource {
    var count = 0
    func snapshot() throws -> [String: Any] { count += 1; return ["settings.showTooltips": true] }
}

private let sampleSettings: [String: Any] = ["settings.showTooltips": true, "settings.toolbarScale": 1.5]

private func root() -> URL { (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() } }

private func pending(_ store: String, _ path: String) -> PendingAuthorization {
    PendingAuthorization(BookmarkFinding(store: store, subject: path, outcome: .unresolvable, action: .dropped))
}

private func seeded(_ items: [PendingAuthorization], into destination: MigrationDestination) {
    try! destination.set(try! PendingAuthorizationList.encode(items), forKey: PendingAuthorizationList.key)
}

/// A service whose panel answers are scripted; it records what it was asked.
private final class Script {
    var already: Set<String> = []
    var answers: [String: AuthorizationPick] = [:]
    var verifies = true
    var asked: [String] = []
    var granted: [String] = []
    var verified: [String] = []

    func service(_ destination: MigrationDestination) -> PendingAuthorizationService {
        PendingAuthorizationService(
            destination: destination,
            isAlreadyAuthorized: { [unowned self] in already.contains($0.path) },
            pick: { [unowned self] item in asked.append(item.path); return answers[item.path] ?? .cancelled },
            grant: { [unowned self] item, _ in granted.append(item.path) },
            verify: { [unowned self] item, _ in verified.append(item.path); return verifies })
    }
}

private let folderStore = "folderAccessBookmarks.v1"
private let recentStore = "recentFiles"

// MARK: - Sandboxed builds

final class SandboxTests: XCTestCase {
    private func flow(_ source: LegacyPreferencesSource, _ destination: MigrationDestination, sandboxed: Bool) -> LegacyMigrationCoordinator {
        LegacyMigrationCoordinator(source: source, destination: destination, isGlossa: true, isSandboxed: sandboxed)
    }

    func testASandboxedBuildDoesNotOfferTheImportAndDoesNotEvenReadTheOldDomain() {
        let destination = Memory()
        let source = Reads()
        XCTAssertEqual(flow(source, destination, sandboxed: true).evaluate(), .notNeeded(.sandboxed))
        XCTAssertEqual(source.count, 0)
        XCTAssertEqual(destination.sets, 0)
    }

    func testTheSameDataIsOfferedByAnUnsandboxedBuild() {
        XCTAssertNotNil(flow(DictionarySource(values: sampleSettings), Memory(), sandboxed: false).evaluate().summary)
        XCTAssertNil(flow(DictionarySource(values: sampleSettings), Memory(), sandboxed: true).evaluate().summary)
    }

    func testASandboxedBuildCannotBeMadeToImportEither() {
        let destination = Memory()
        let outcome = flow(DictionarySource(values: sampleSettings), destination, sandboxed: true).choose(.importNow)
        guard case .failed(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(reason, MigrationOffer.Reason.sandboxed.explanation)
        XCTAssertTrue(destination.store.isEmpty, "nothing written, no marker")
    }

    func testAFinishedImportOrARefusalIsReportedAsThatEvenInASandboxedBuild() {
        let done = Memory()
        done.store[MigrationMarker.key] = Data()
        XCTAssertEqual(flow(Reads(), done, sandboxed: true).evaluate(), .notNeeded(.alreadyMigrated))
        let refused = Memory()
        refused.store[MigrationDeclined.key] = Data()
        XCTAssertEqual(flow(Reads(), refused, sandboxed: true).evaluate(), .notNeeded(.declined))
    }

    func testTheExplanationNamesTheSandboxAndTheBuildThatCanImport() {
        let text = MigrationOffer.Reason.sandboxed.explanation
        XCTAssertTrue(text.contains("sandbox"))
        XCTAssertTrue(text.contains("Release-Direct"))
        let reasons: [MigrationOffer.Reason] = [.notGlossa, .alreadyMigrated, .declined, .noLegacyData, .sourceUnreadable("x"), .nothingToImport, .sandboxed]
        for reason in reasons { XCTAssertFalse(reason.explanation.isEmpty) }
        XCTAssertEqual(Set(reasons.map(\.explanation)).count, reasons.count, "each reason says something of its own")
    }

    func testTheTestProcessItselfIsNotSandboxed() {
        XCTAssertFalse(AppSandbox.isActive, "the check reads the process's own entitlements")
    }

    func testTheEntitlementsAreAsTheyWere() throws {
        let sandboxed = try String(contentsOf: root().appendingPathComponent("Glossa/PageFlow.entitlements"), encoding: .utf8)
        let direct = try String(contentsOf: root().appendingPathComponent("Glossa/PageFlow-Direct.entitlements"), encoding: .utf8)
        XCTAssertTrue(sandboxed.contains("com.apple.security.app-sandbox"), "the sandboxed configuration is still sandboxed")
        XCTAssertFalse(direct.contains("com.apple.security.app-sandbox"), "Release-Direct is still not")
        XCTAssertFalse(sandboxed.contains("shared-preference"), "no temporary exception was added to read PageFlow's preferences")
    }

    func testAnotherDomainIsReadThroughCFPreferencesAndTheFileIsNotChanged() throws {
        // The unsandboxed path: a preferences domain that is not the app's own, read and never written.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-cf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let domain = dir.appendingPathComponent("legacy").path
        let plist = URL(fileURLWithPath: domain + ".plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["settings.showTooltips": true, "settings.toolbarScale": 1.5], format: .binary, options: 0)
        try data.write(to: plist)

        let snapshot = try CFPreferencesDomainSource(domain: domain).snapshot()
        XCTAssertEqual(snapshot["settings.showTooltips"] as? Bool, true)
        XCTAssertEqual(snapshot["settings.toolbarScale"] as? Double, 1.5)
        XCTAssertEqual(try Data(contentsOf: plist), data, "reading did not rewrite the file")
    }

    func testTheMenuExplainsWhyWhenTheImportIsNotAvailable() throws {
        let presenter = try String(contentsOf: root().appendingPathComponent("Glossa/Migration/MigrationPresenter.swift"), encoding: .utf8)
        XCTAssertTrue(presenter.contains("static func importFromMenu()"))
        XCTAssertTrue(presenter.contains("Importing is not available in this build"))
        XCTAssertTrue(presenter.contains("prompt.explanations"))
        let app = try String(contentsOf: root().appendingPathComponent("Glossa/PageFlowApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("Button(\"Import from PageFlow…\") { MigrationPresenter.importFromMenu() }"))
    }

    func testTheLaunchPromptStaysSilentWhenTheImportIsNotAvailable() throws {
        // Only an offer opens a window at launch; "not needed" (including sandboxed) opens none.
        let presenter = try String(contentsOf: root().appendingPathComponent("Glossa/Migration/MigrationPresenter.swift"), encoding: .utf8)
        XCTAssertTrue(presenter.contains("if prompt.hasOffer"))
    }
}

// MARK: - The permissions to allow again

final class AuthorizationManagerTests: XCTestCase {
    func testTheMenuItemIsThereAndFollowsTheList() throws {
        let app = try String(contentsOf: root().appendingPathComponent("Glossa/PageFlowApp.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("Button(\"Manage Authorizations to Restore…\") { MigrationPresenter.showAuthorizationManager() }"))
        XCTAssertTrue(app.contains(".disabled(pendingAuthorizations.items.isEmpty)"), "available only when something is pending")
        let presenter = try String(contentsOf: root().appendingPathComponent("Glossa/Migration/MigrationPresenter.swift"), encoding: .utf8)
        XCTAssertTrue(presenter.contains("static func showAuthorizationManager()"))
    }

    func testAGrantedAuthorizationLeavesTheListOnlyAfterItIsVerified() {
        let destination = Memory()
        seeded([pending(folderStore, "/a/Notes"), pending(recentStore, "/a/Book.pdf")], into: destination)
        let script = Script()
        script.answers["/a/Notes"] = .chosen(URL(fileURLWithPath: "/a/Notes"))
        let service = script.service(destination)

        XCTAssertEqual(service.attempt(service.list()[0]), .granted)
        XCTAssertEqual(script.granted, ["/a/Notes"])
        XCTAssertEqual(script.verified, ["/a/Notes"], "verified after it was stored")
        XCTAssertEqual(service.list().map(\.path), ["/a/Book.pdf"], "the one that was not resolved stays")
    }

    func testCancellingThePanelChangesNothing() {
        let destination = Memory()
        seeded([pending(folderStore, "/a/Notes")], into: destination)
        let script = Script()    // no answer scripted: the reader cancels
        let service = script.service(destination)
        let before = destination.store[PendingAuthorizationList.key] as? Data
        XCTAssertEqual(service.attempt(service.list()[0]), .cancelled)
        XCTAssertTrue(script.granted.isEmpty)
        XCTAssertEqual(destination.store[PendingAuthorizationList.key] as? Data, before)
        XCTAssertEqual(destination.sets, 1, "only the seeding")
    }

    func testAnAccessThatCannotBeVerifiedKeepsTheEntry() {
        let destination = Memory()
        seeded([pending(recentStore, "/a/Book.pdf")], into: destination)
        let script = Script()
        script.answers["/a/Book.pdf"] = .chosen(URL(fileURLWithPath: "/a/Book.pdf"))
        script.verifies = false
        let service = script.service(destination)
        XCTAssertEqual(service.attempt(service.list()[0]), .notVerified)
        XCTAssertEqual(service.list().map(\.path), ["/a/Book.pdf"])
    }

    func testTheWrongFileIsRefusedAndNothingIsStored() {
        let destination = Memory()
        seeded([pending(recentStore, "/a/Book.pdf")], into: destination)
        let script = Script()
        script.answers["/a/Book.pdf"] = .chosen(URL(fileURLWithPath: "/a/Other.pdf"))
        let service = script.service(destination)
        XCTAssertEqual(service.attempt(service.list()[0]), .wrongSelection(expected: "Book.pdf"))
        XCTAssertTrue(script.granted.isEmpty)
        XCTAssertEqual(service.list().count, 1)
    }

    func testAFolderThatContainsTheOneNamedIsAcceptedAnUnrelatedOneIsNot() {
        let item = pending(folderStore, "/a/Notes/Sub")
        XCTAssertTrue(PendingAuthorizationService.matches(item, chosen: URL(fileURLWithPath: "/a/Notes/Sub")))
        XCTAssertTrue(PendingAuthorizationService.matches(item, chosen: URL(fileURLWithPath: "/a/Notes")))
        XCTAssertFalse(PendingAuthorizationService.matches(item, chosen: URL(fileURLWithPath: "/a/Not")))
        XCTAssertFalse(PendingAuthorizationService.matches(item, chosen: URL(fileURLWithPath: "/b")))
        XCTAssertFalse(PendingAuthorizationService.matches(pending(recentStore, "/a/Notes/x.pdf"), chosen: URL(fileURLWithPath: "/a/Notes")),
                       "a file has to be the file")
    }

    func testAnAccessThatAlreadyWorksIsNotAskedForAgain() {
        let destination = Memory()
        seeded([pending(folderStore, "/a/Notes"), pending(recentStore, "/a/Book.pdf")], into: destination)
        let script = Script()
        script.already = ["/a/Notes"]
        let service = script.service(destination)
        XCTAssertEqual(service.attempt(service.list()[0]), .alreadyAuthorized)
        XCTAssertTrue(script.asked.isEmpty, "no panel for something that already works")
        XCTAssertTrue(script.granted.isEmpty)
        XCTAssertEqual(service.list().map(\.path), ["/a/Book.pdf"])
    }

    func testAFailureToSaveTheListKeepsTheEntry() {
        let destination = Memory()
        seeded([pending(folderStore, "/a/Notes"), pending(folderStore, "/a/Other")], into: destination)
        destination.failOnSet = 2    // the write that removes one entry
        let script = Script()
        script.answers["/a/Notes"] = .chosen(URL(fileURLWithPath: "/a/Notes"))
        let service = script.service(destination)
        XCTAssertEqual(service.attempt(service.list()[0]), .notVerified)
        XCTAssertEqual(service.list().count, 2)
    }

    func testTheListSurvivesRestartsAndOnlyResolvedEntriesLeaveIt() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-restart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let suiteName = dir.appendingPathComponent("glossa").path
        func launch() -> UserDefaultsDestination { UserDefaultsDestination(defaults: UserDefaults(suiteName: suiteName)!) }

        // First launch: an import that leaves three paths to allow again.
        let source: [String: Any] = ["folderAccessBookmarks.v1": ["/a": Data("x".utf8), "/b": Data("y".utf8), "/c": Data("z".utf8)],
                                     "settings.showTooltips": true]
        let first = launch()
        let flow = LegacyMigrationCoordinator(source: DictionarySource(values: source), destination: first, isGlossa: true, isSandboxed: false)
        guard case .imported = flow.choose(.importNow) else { return XCTFail() }
        XCTAssertEqual(PendingAuthorizationList.read(from: first).map(\.path).sorted(), ["/a", "/b", "/c"])

        // Second launch: nothing was resolved; the reader cancels once.
        let second = launch()
        let cancelling = Script()
        let secondService = cancelling.service(second)
        XCTAssertEqual(secondService.attempt(secondService.list()[0]), .cancelled)
        XCTAssertEqual(secondService.list().count, 3)

        // Third launch: one is allowed.
        let third = launch()
        let allowing = Script()
        allowing.answers["/b"] = .chosen(URL(fileURLWithPath: "/b"))
        let thirdService = allowing.service(third)
        let b = try XCTUnwrap(thirdService.list().first { $0.path == "/b" })
        XCTAssertEqual(thirdService.attempt(b), .granted)

        // Fourth launch: the other two are still there, and the import is not offered again.
        let fourth = launch()
        XCTAssertEqual(PendingAuthorizationList.read(from: fourth).map(\.path).sorted(), ["/a", "/c"])
        let again = LegacyMigrationCoordinator(source: DictionarySource(values: source), destination: fourth, isGlossa: true, isSandboxed: false)
        XCTAssertEqual(again.evaluate(), .notNeeded(.alreadyMigrated))
    }

    func testTheLaunchPromptIsShownOnceAndTheMenuBringsTheListBack() throws {
        let presenter = try String(contentsOf: root().appendingPathComponent("Glossa/Migration/MigrationPresenter.swift"), encoding: .utf8)
        XCTAssertTrue(presenter.contains("takeAuthorizationPrompt(pendingCount:"), "the first launch after an import asks once (the rule is the coordinator's)")
        XCTAssertTrue(presenter.contains("PendingAuthorizationsModel.shared.refresh()"), "the list is read from the preferences, so it is the same after any restart")
    }
}
