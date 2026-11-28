//
//  CombinedMigrationCoordinator.swift
//  PageFlow
//
//  One offer for the two independent units:
//    A  the preferences (`LegacyMigrationCoordinator`: marker and refusal in Glossa's preferences);
//    B  the files under Application Support (`AppSupportMigrator`: marker file in Glossa's folder,
//       refusal in Glossa's preferences).
//  The window appears when A or B is available. B is offered even when A was imported earlier, and is
//  not offered when the reader refused A for good. Each choice acts on what was offered, and each unit
//  keeps its own record: "Don't Import Ever" writes A's refusal and/or B's, never the other's marker.
//
//    Import        runs A (if offered), then B (if offered). Over the attachments threshold B waits for a
//                  confirmation and copies nothing until it is given.
//    Not Now       writes nothing, for either unit.
//    Don't Import  writes the refusal of each unit that was offered, and nothing else.
//
//  A needs a restart (the stores read their preferences at launch); B does not: its folders are read by
//  stores that are created after the offer. `needsRestart` is true only when A was applied.
//

import Foundation

nonisolated struct MigrationPrompt: Equatable, Sendable {
    var preferences: MigrationOffer
    var files: FilesAvailability

    var hasOffer: Bool { preferences.summary != nil || files.offer != nil }

    /// Why each unit is not available, for the menu: what has no offer, and the reason.
    var explanations: [String] {
        var lines: [String] = []
        if case .notNeeded(let reason) = preferences { lines.append("Settings: " + reason.explanation) }
        if case .unavailable(let reason) = files { lines.append("Files: " + reason.explanation) }
        return lines
    }

    /// Whether the sandbox is why something cannot be imported.
    var isBlockedBySandbox: Bool {
        if case .notNeeded(.sandboxed) = preferences { return true }
        if case .unavailable(.sandboxed) = files { return true }
        return false
    }
}

nonisolated struct CombinedOutcome: Equatable, Sendable {
    /// What happened to the preferences; nil when they were not offered.
    var preferences: MigrationOutcome?
    /// What happened to the files; nil when they were not offered or did not run.
    var files: AppSupportMigrationReport?
    /// The files wait for the reader to confirm a large amount of attachments (bytes).
    var filesNeedConfirmation: Int64?
    var postponed = false
    var declinedPreferences = false
    var declinedFiles = false
    /// The preferences were applied: Glossa has to restart before anything else is written.
    var needsRestart = false
    /// Something that stopped the choice (a refusal that could not be saved, a failed import).
    var failure: String?
}

/// Used by one task at a time (the window hands it to a background task and waits): its parts are
/// value types around thread-safe stores, which is why the conformance is unchecked.
nonisolated struct CombinedMigrationCoordinator: @unchecked Sendable {
    var preferences: LegacyMigrationCoordinator
    var files: AppSupportMigrator

    var destination: MigrationDestination { preferences.destination }
    var isGlossa: Bool { preferences.isGlossa }
    var appVersion: String { preferences.appVersion }

    // MARK: Deciding

    /// Reads, never writes: A's dry run, and for B the marker, the refusals and a count of PageFlow's files.
    func evaluate() -> MigrationPrompt {
        MigrationPrompt(preferences: preferences.evaluate(), files: evaluateFiles())
    }

    func evaluateFiles() -> FilesAvailability {
        guard isGlossa else { return .unavailable(.notGlossa) }
        // A sandboxed build is told before anything is looked at: PageFlow's folder is not read.
        guard files.paths.legacyIsReachable else { return .unavailable(.sandboxed) }
        switch files.status() {
        case .completed: return .unavailable(.alreadyCopied)
        case .markerInvalid: return .unavailable(.markerInvalid)
        case .legacyUnreachable: return .unavailable(.sandboxed)
        case .interrupted, .notStarted: break
        }
        if destination.value(forKey: AppSupportDeclined.key) != nil { return .unavailable(.declined) }
        // D2: refusing the preferences for good means nothing of PageFlow's is offered.
        if destination.value(forKey: MigrationDeclined.key) != nil { return .unavailable(.preferencesDeclined) }
        let candidates = AppSupportCandidates(paths: files.paths, fileManager: files.fileManager)
        let lines = candidates.lines()
        let unreadable = candidates.unreadableFolders()
        guard !lines.isEmpty else {
            if !unreadable.isEmpty { return .unavailable(.legacyFolderUnreadable) }
            return .unavailable(candidates.hasLinkedFolder() ? .legacyFolderIsLink : .nothingToCopy)
        }
        var interrupted = false
        if case .interrupted = files.status() { interrupted = true }
        return .offer(FilesOffer(lines: lines, unreadable: unreadable, interrupted: interrupted))
    }

    // MARK: Orphan staging

    /// Staging folders left by a cut-off copy that no offer will ever pick up: there is nothing in PageFlow
    /// to copy (or only links), or the reader refused the files. They are Glossa's own leftovers and are
    /// removed. This is its own step, called at launch; `evaluate()` and `status()` stay read-only.
    ///
    /// Nothing is removed when:
    ///  - an offer exists (the next copy starts over by itself, and the reader may still choose it);
    ///  - the copy is recorded as done, the marker is unreadable, the build is sandboxed or is not Glossa;
    ///  - the folder was touched within `minimumAge` (another copy may be running).
    /// Returns how many folders were removed.
    @discardableResult
    func tidyOrphanStaging(minimumAge: TimeInterval = 3600, now: Date = Date()) -> Int {
        guard case .unavailable(let reason) = evaluateFiles() else { return 0 }
        switch reason {
        case .nothingToCopy, .legacyFolderIsLink, .legacyFolderUnreadable, .declined, .preferencesDeclined:
            return files.removeOwnStaging(minimumAge: minimumAge, now: now)
        case .notGlossa, .sandboxed, .alreadyCopied, .markerInvalid:
            return 0
        }
    }

    // MARK: Permissions to allow again

    static let authorizationPromptedKey = "glossa.migration.fromPageFlow.authorizationPrompted.v1"

    /// Whether the list of permissions to allow again is shown now: the first launch it is not empty and
    /// has not been shown yet. Records that it was shown. Called once the import window, if there was
    /// one, is gone, so the two never overlap; the menu brings the list back whenever it is wanted.
    func takeAuthorizationPrompt(pendingCount: Int) -> Bool {
        guard destination.value(forKey: Self.authorizationPromptedKey) == nil, pendingCount > 0 else { return false }
        try? destination.set(true, forKey: Self.authorizationPromptedKey)
        return true
    }

    // MARK: Choosing

    /// `isCancelled` is asked by the file copy only (see `AppSupportMigrator.isCancelled`); the preferences
    /// are written in one short step that is never cut off.
    func choose(_ choice: MigrationChoice, confirmLargeAttachments: Bool = false, now: Date = Date(),
                isCancelled: @escaping () -> Bool = { false }, pointOfNoReturn: @escaping () -> Void = {}) -> CombinedOutcome {
        let prompt = evaluate()      // the same guards as the offer: a stale window cannot import what is no longer offered
        var outcome = CombinedOutcome()
        let offeredPreferences = prompt.preferences.summary != nil
        let offeredFiles = prompt.files.offer != nil

        switch choice {
        case .notNow:
            outcome.postponed = true      // nothing is written, for either unit
            return outcome

        case .neverImport:
            if offeredPreferences {
                let result = preferences.choose(.neverImport, now: now)
                outcome.preferences = result
                if case .failed(let reason) = result { outcome.failure = reason; return outcome }
                outcome.declinedPreferences = true
            }
            if offeredFiles {
                let record = AppSupportDeclined(version: AppSupportDeclined.currentVersion,
                                                decidedAt: ISO8601DateFormatter().string(from: now), appVersion: appVersion)
                do {
                    try destination.set(try JSONEncoder().encode(record), forKey: AppSupportDeclined.key)
                    outcome.declinedFiles = true
                    files.removeOwnStaging()      // refused for good: a cut-off run's leftovers go, only after the refusal is saved
                } catch {
                    outcome.failure = "the decision about the files could not be saved: \(error.localizedDescription)"
                }
            }
            return outcome

        case .importNow:
            if offeredPreferences {
                let result = preferences.choose(.importNow, now: now)
                outcome.preferences = result
                switch result {
                case .failed(let reason): outcome.failure = reason; return outcome      // nothing of A is recorded; B is not tried
                case .imported(let report): outcome.needsRestart = report.state == .applied
                default: break
                }
            }
            if offeredFiles { applyFiles(confirmLargeAttachments: confirmLargeAttachments, isCancelled: isCancelled, pointOfNoReturn: pointOfNoReturn, to: &outcome) }
            return outcome
        }
    }

    /// The file copy alone, for the step after a confirmation was asked. Re-checks that it is still offered.
    func copyFiles(confirmLargeAttachments: Bool, isCancelled: @escaping () -> Bool = { false },
                   pointOfNoReturn: @escaping () -> Void = {}) -> CombinedOutcome {
        var outcome = CombinedOutcome()
        guard evaluateFiles().offer != nil else {
            outcome.failure = "the files are no longer offered"
            return outcome
        }
        applyFiles(confirmLargeAttachments: confirmLargeAttachments, isCancelled: isCancelled, pointOfNoReturn: pointOfNoReturn, to: &outcome)
        return outcome
    }

    private func applyFiles(confirmLargeAttachments: Bool, isCancelled: @escaping () -> Bool,
                            pointOfNoReturn: @escaping () -> Void, to outcome: inout CombinedOutcome) {
        var migrator = files
        migrator.isCancelled = isCancelled
        migrator.pointOfNoReturn = pointOfNoReturn
        let report = migrator.run(confirmLargeAttachments: confirmLargeAttachments)
        if case .needsConfirmation(let bytes) = report.state { outcome.filesNeedConfirmation = bytes }
        outcome.files = report
    }
}

// MARK: - The result in the reader's words

nonisolated struct FilesResultSummary: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var category: ApplicationSupportPaths.Category
        var copied: Int
        var identical: Int
        var conflicts: Int
        var bytes: Int64
    }

    var lines: [Line] = []
    var copiedFiles = 0
    var copiedBytes: Int64 = 0
    var identical = 0
    var conflicts = 0
    /// Files found not sound, which were skipped.
    var invalid = 0
    /// Of those, JSON files over the size limit.
    var overJSONLimit = 0
    var failures = 0
    var completed = false
    /// A sentence for what stopped it, when it did not complete.
    var problem: String?

    init(_ report: AppSupportMigrationReport) {
        for category in ApplicationSupportPaths.Category.allCases {
            let entries = report.entries(category)
            guard !entries.isEmpty else { continue }
            let copied = entries.filter { $0.outcome == .copied }
            lines.append(Line(category: category, copied: copied.count,
                              identical: entries.filter { $0.outcome == .identical }.count,
                              conflicts: report.conflicts.filter { $0.category == category }.count,
                              bytes: copied.reduce(0) { $0 + $1.size }))
        }
        copiedFiles = report.copied.count
        copiedBytes = report.copiedBytes
        identical = report.identical.count
        conflicts = report.conflicts.count
        invalid = report.invalid.count
        overJSONLimit = report.overJSONLimit.count
        failures = report.failures.count
        switch report.state {
        case .completed: completed = true
        case .alreadyCompleted: completed = true
        case .partial(let unreadable):
            let names = unreadable.map { $0.folderName }.joined(separator: ", ")
            problem = "Glossa could not read \(names) in PageFlow's folder, (the folder, or some of its files), so the copy is not recorded as done. What could be read was copied. Check the folder's permissions and start Glossa again: it will be offered again, and nothing is copied twice."
        case .incomplete: problem = "\(failures) file\(failures == 1 ? "" : "s") could not be copied and checked, so the copy is not recorded as done and will be offered again."
        case .failed(let reason): problem = "The copy stopped: \(reason). It is not recorded as done and will be offered again."
        case .insufficientSpace(let required, _): problem = "There is not enough free space (about \(Self.mebibytes(required)) needed). Nothing was copied."
        case .markerInvalid: problem = FilesUnavailableReason.markerInvalid.explanation
        case .legacyUnreachable: problem = FilesUnavailableReason.sandboxed.explanation
        case .nothingToCopy: problem = "There was nothing sound to copy."
        case .needsConfirmation: problem = "Waiting for your confirmation."
        case .cancelled: problem = "The copy was cancelled. Nothing was copied, and it will be offered again."
        }
    }

    /// Sizes are binary (1 MiB = 1,048,576 bytes), and written so.
    static func mebibytes(_ bytes: Int64) -> String { String(format: "%.0f MiB", Double(bytes) / 1_048_576) }
}
