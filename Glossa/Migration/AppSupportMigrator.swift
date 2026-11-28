//
//  AppSupportMigrator.swift
//  Glossa
//
//  Copies the files the scanner found sound from PageFlow's Application Support folders into
//  Glossa's. It is called by `CombinedMigrationCoordinator` when the reader chooses Import, from a
//  background task (`MigrationSession`); nothing else starts it, and it never runs on its own.
//
//  PageFlow's folder is only ever read. Everything written is under Glossa's root:
//    1. the attachments are counted with `lstat` only (no file opened). Over the threshold (500 MiB, an
//       upper bound: it counts every regular file) and without an explicit confirmation, the run stops
//       here, before anything is hashed or copied;
//    2. scan (read-only); nothing sound, nothing to do (and a cut-off run's staging is removed);
//    3. the same threshold check on what the scan found sound, for files that grew since the count;
//    4. files Glossa already has are settled without being copied again (identical to PageFlow's, or
//       different, in which case Glossa's wins) if PageFlow's file is still as the scan saw it; room on
//       the disk is then checked for the files left to copy only (their size plus a tenth, plus a margin);
//    5. each file left is copied into `.import-staging-<runId>/` and its SHA-256 compared with the scan's,
//       and the source is checked not to have changed (size and date) before and after the copy;
//    6. staged files are moved into their folders one at a time with a rename, which never replaces
//       anything: a file Glossa already has wins. The same content is "identical", other content a
//       "conflict"; in both the staged copy is dropped and PageFlow's file is left alone;
//    7. only when every file is accounted for, the marker `.migration-appsupport-v1.json` is written
//       atomically, last. Without it the migration is not complete, whatever else is on the disk.
//
//  Cancelling (`isCancelled`, asked between files and chunks) stops a run cleanly up to the start of
//  step 6: staging removed, no marker, nothing in Glossa's folders. From step 6 on the run goes to the
//  end, so a cancel that arrives later has no effect and the result says what was done.
//
//  A run that is cut off leaves its staging folder and no marker. `status()` reports that as
//  interrupted so the reader is offered the copy again; nothing resumes by itself. A new run first
//  removes the staging folders of earlier runs (Glossa's own, nothing of PageFlow's), then starts over;
//  what was already moved into place is identical and counts as such.
//
//  JSON files over `AppSupportScanner.jsonLimit` (64 MiB) are not copied: the scanner reports them
//  invalid (`tooLarge`), and they are listed in the report and in the marker.
//

import CryptoKit
import Foundation

// MARK: - Marker

nonisolated struct AppSupportMarker: Codable, Equatable, Sendable {
    static let fileName = ".migration-appsupport-v1.json"
    static let currentVersion = 1

    enum Status: String, Codable, Sendable { case completed }

    struct FileRecord: Codable, Equatable, Sendable {
        var category: String
        var name: String
        var size: Int64
        var sha256: String
        /// `copied`, `identical` or `conflict`.
        var outcome: String
    }

    struct InvalidRecord: Codable, Equatable, Sendable {
        var category: String
        var name: String
        var reason: String
        var sha256: String?
    }

    var version: Int
    var status: Status
    var completedAt: String
    var appVersion: String
    var runId: String
    /// PageFlow's folder the files came from.
    var source: String
    /// JSON files larger than this are not copied.
    var jsonLimitBytes: Int
    var files: [FileRecord]
    var invalid: [InvalidRecord]
    var skippedCount: Int

    static func url(in glossaRoot: URL) -> URL { glossaRoot.appendingPathComponent(fileName) }
}

// MARK: - Status and report

nonisolated enum AppSupportMigrationStatus: Equatable, Sendable {
    /// A sandboxed build: PageFlow's folder is out of reach.
    case legacyUnreachable
    /// A valid marker is there: done.
    case completed(AppSupportMarker)
    /// A marker file is there but is not a valid one. It is not overwritten.
    case markerInvalid
    /// An earlier run left staging folders and no marker: offer the copy again.
    case interrupted(stagingFolders: [String])
    case notStarted
}

nonisolated enum AppSupportFileOutcome: Equatable, Sendable {
    /// Moved into Glossa's folder.
    case copied
    /// Glossa already had a file of this name with the same content.
    case identical
    /// Glossa already had a file of this name with other content (or something that is not a file): it wins.
    case conflict(String)
    /// Could not be copied and verified: the migration is not complete.
    case failed(String)
}

nonisolated struct AppSupportMigrationEntry: Equatable, Sendable {
    var category: ApplicationSupportPaths.Category
    var name: String
    var size: Int64
    var sha256: String
    var outcome: AppSupportFileOutcome
}

nonisolated struct AppSupportMigrationReport: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Everything accounted for and the marker written.
        case completed
        /// A valid marker was already there: nothing was done.
        case alreadyCompleted
        case legacyUnreachable
        /// Nothing sound in PageFlow's folders: nothing copied and no marker.
        case nothingToCopy
        /// The attachments are over the threshold and were not confirmed: nothing was written.
        case needsConfirmation(attachmentBytes: Int64)
        /// Not enough room: nothing was written. `available` is nil when it could not be read.
        case insufficientSpace(required: Int64, available: Int64?)
        /// A marker file that is not valid is in the way: nothing was written.
        case markerInvalid
        /// Some folder of PageFlow's could not be read. What could be read was copied (idempotently), but no
        /// marker is written: the copy is not complete, and is offered again until those folders can be read.
        case partial(unreadable: [ApplicationSupportPaths.Category])
        /// A file could not be copied and verified: no marker; the offer comes back.
        case incomplete
        /// Cancelled by the caller before anything was moved into place: no marker, staging removed.
        case cancelled
        /// Stopped by an error or a cut-off: no marker.
        case failed(String)
    }

    var state: State
    var scan: AppSupportScanReport?
    var entries: [AppSupportMigrationEntry] = []

    func entries(_ category: ApplicationSupportPaths.Category) -> [AppSupportMigrationEntry] { entries.filter { $0.category == category } }
    private func bytes(_ match: (AppSupportFileOutcome) -> Bool) -> Int64 { entries.filter { match($0.outcome) }.reduce(0) { $0 + $1.size } }

    var copied: [AppSupportMigrationEntry] { entries.filter { $0.outcome == .copied } }
    var identical: [AppSupportMigrationEntry] { entries.filter { $0.outcome == .identical } }
    var conflicts: [AppSupportMigrationEntry] { entries.filter { if case .conflict = $0.outcome { return true } else { return false } } }
    var failures: [AppSupportMigrationEntry] { entries.filter { if case .failed = $0.outcome { return true } else { return false } } }
    var copiedBytes: Int64 { bytes { $0 == .copied } }
    var identicalBytes: Int64 { bytes { $0 == .identical } }
    var conflictBytes: Int64 { bytes { if case .conflict = $0 { return true } else { return false } } }

    /// Files the scan found not sound; they are not copied (and do not stop the rest).
    var invalid: [AppSupportScannedFile] { scan?.invalidFiles ?? [] }
    /// The JSON files over the size limit, among the invalid ones.
    var overJSONLimit: [AppSupportScannedFile] { invalid.filter { $0.verdict == .invalid(.tooLarge) } }
    var skipped: [AppSupportSkippedEntry] { scan?.skipped ?? [] }
}

nonisolated extension AppSupportInvalidReason {
    var text: String {
        switch self {
        case .unreadable(let detail): return "unreadable: \(detail)"
        case .empty: return "empty"
        case .tooLarge: return "over the \(AppSupportScanner.jsonLimit / (1024 * 1024)) MiB limit for JSON files"
        case .notJSON: return "not JSON"
        case .wrongStructure(let detail): return "not what the app stores (\(detail))"
        case .nameDoesNotMatchContent: return "its name does not match its content"
        case .notAnImage(let detail): return "not an image (\(detail))"
        }
    }
}

// MARK: - Migrator

nonisolated struct AppSupportMigrator {
    /// Attachments above this many bytes (500 MiB) need an explicit confirmation before any copy.
    static let defaultLargeAttachmentsThreshold: Int64 = 500 * 1024 * 1024
    static let stagingPrefix = ".import-staging-"
    /// Room needed: the files plus a tenth, plus this.
    static let spaceMargin: Int64 = 1024 * 1024

    /// Points in a run, for tests to cut it off at. A hook that throws stops the run where a crash would:
    /// nothing is cleaned up.
    enum Checkpoint: Equatable {
        case stagingCreated
        case staged(ApplicationSupportPaths.Category, String)
        case merged(ApplicationSupportPaths.Category, String)
        case beforeMarker
    }

    struct Interrupted: Error {}

    var paths: ApplicationSupportPaths
    var fileManager: FileManager = .default
    /// Settable so a test need not build 500 MiB of files.
    var largeAttachmentsThreshold = AppSupportMigrator.defaultLargeAttachmentsThreshold
    var appVersion = ""
    var now: () -> Date = Date.init
    var makeRunID: () -> String = { UUID().uuidString }
    /// Free bytes on the volume that holds `url`; nil when unknown.
    var availableSpace: (URL) -> Int64? = AppSupportMigrator.systemAvailableSpace
    var checkpoint: (Checkpoint) throws -> Void = { _ in }
    /// Asked while scanning and while staging, never once files start to be moved into place: a run is
    /// stopped before that point, cleanly (staging removed, no marker), or it goes on to the end.
    var isCancelled: () -> Bool = { false }
    /// Called once, from the copying task, right after the last cancel check and before the first file is
    /// moved into place: from then on the run cannot be stopped. It only tells; it changes nothing.
    var pointOfNoReturn: () -> Void = {}

    // MARK: Status

    /// Looks at Glossa's folder only. Reads PageFlow's nothing.
    func status() -> AppSupportMigrationStatus {
        guard paths.legacyIsReachable else { return .legacyUnreachable }
        switch readMarker() {
        case .valid(let marker): return .completed(marker)
        case .invalid: return .markerInvalid
        case .absent: break
        }
        let staging = stagingFolders()
        return staging.isEmpty ? .notStarted : .interrupted(stagingFolders: staging)
    }

    // MARK: Run

    func run(confirmLargeAttachments: Bool = false) -> AppSupportMigrationReport {
        guard paths.legacyIsReachable else { return .init(state: .legacyUnreachable) }
        switch readMarker() {
        case .valid: return .init(state: .alreadyCompleted)
        case .invalid: return .init(state: .markerInvalid)
        case .absent: break
        }

        // The size of the attachments, from a count that opens no file: over the threshold the reader is
        // asked before anything is hashed or copied. (It includes files the scan may find not sound, so it
        // is an upper bound.)
        let counter = AppSupportCandidates(paths: paths, fileManager: fileManager)
        let candidates = counter.lines()
        let candidateAttachmentBytes = candidates.first { $0.category == .attachments }?.bytes ?? 0
        if candidateAttachmentBytes > largeAttachmentsThreshold, !confirmLargeAttachments {
            return .init(state: .needsConfirmation(attachmentBytes: candidateAttachmentBytes))
        }
        if isCancelled() { return .init(state: .cancelled) }

        let unreadableAtStart = counter.unreadableFolders()      // after the threshold question: that one lists nothing more
        var scanner = AppSupportScanner(paths: paths, fileManager: fileManager)
        scanner.isCancelled = isCancelled
        let scan = scanner.scan()
        if isCancelled() { return .init(state: .cancelled) }      // a partial scan is not used
        var report = AppSupportMigrationReport(state: .nothingToCopy, scan: scan)
        let valid = scan.validFiles
        // What could not be read, seen before the scan or by it: a folder, or a file in it (permissions). It
        // is never "nothing there" and never "not sound": while any is unreadable the copy is not recorded as
        // done, and it is tried again once it can be read.
        let unreadable = ApplicationSupportPaths.Category.allCases.filter { category in
            if unreadableAtStart.contains(category) { return true }
            guard let categoryReport = scan.report(for: category) else { return false }
            if case .unreadable = categoryReport.state { return true }
            return categoryReport.files.contains { file in
                if case .invalid(.unreadable) = file.verdict { return true }
                return false
            }
        }
        // Nothing sound to copy. Unreadable things: not done, try again. Files that are all permanently not
        // sound (and nothing unreadable): there is nothing more to wait for, so the run goes on to record
        // that, with the list of what was skipped. No file at all: nothing to record.
        let onlyPermanentlyInvalid = unreadable.isEmpty && !scan.invalidFiles.isEmpty
        guard !valid.isEmpty || onlyPermanentlyInvalid else {
            removeOwnStaging()      // nothing to copy: whatever an earlier, cut-off run left is of no use
            if !unreadable.isEmpty { report.state = .partial(unreadable: unreadable) }
            return report
        }

        // The same check on what the scan found sound, for files that grew since the count.
        let attachmentBytes = scan.report(for: .attachments)?.validBytes ?? 0
        if attachmentBytes > largeAttachmentsThreshold, !confirmLargeAttachments {
            report.state = .needsConfirmation(attachmentBytes: attachmentBytes)
            return report
        }

        // Files Glossa already has are settled here and are not copied again: identical to PageFlow's (a
        // retry after an earlier, partial copy) or different (Glossa's wins, as at the merge). Only when the
        // source is still as the scan saw it; otherwise it goes the normal way, with every check.
        var toCopy: [AppSupportScannedFile] = []
        for file in valid {
            if isCancelled() { return .init(state: .cancelled) }      // nothing is written yet
            let target = paths.directory(for: file.category).appendingPathComponent(file.name)
            if let outcome = existingOutcome(at: target, for: file), sourceIsAsScanned(file) {
                report.entries.append(entry(file, outcome))
            } else {
                toCopy.append(file)
            }
        }

        // Room is needed for what is going to be copied, and for nothing else.
        if !toCopy.isEmpty {
            let total = toCopy.reduce(Int64(0)) { $0 + $1.size }
            let required = total + total / 10 + Self.spaceMargin
            let available = availableSpace(nearestExistingFolder(of: paths.glossaRoot))
            guard let available, available >= required else {
                report.state = .insufficientSpace(required: required, available: available)
                report.entries = []
                return report
            }
        }

        do { try fileManager.createDirectory(at: paths.glossaRoot, withIntermediateDirectories: true) }
        catch { report.state = .failed("Glossa's folder could not be created: \(error.localizedDescription)"); return report }

        removeStagingFolders()   // earlier, cut-off runs: ours, inside Glossa's folder only
        let runID = makeRunID()
        let staging = paths.glossaRoot.appendingPathComponent(Self.stagingPrefix + runID, isDirectory: true)

        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try checkpoint(.stagingCreated)
        } catch is Interrupted {
            report.state = .failed("interrupted"); return report
        } catch {
            report.state = .failed("the staging folder could not be created: \(error.localizedDescription)")
            return report
        }

        // Copy and verify.
        var staged: [AppSupportScannedFile] = []
        for file in toCopy {
            if isCancelled() { return cancelled(&report, staging: staging) }
            do {
                if let failure = stage(file, in: staging) {
                    report.entries.append(entry(file, .failed(failure)))
                } else {
                    staged.append(file)
                }
                try checkpoint(.staged(file.category, file.name))
            } catch {
                report.state = .failed("interrupted"); return report      // as a crash: staging stays
            }
        }

        // The last point at which a run can be stopped: nothing is in its folder yet.
        if isCancelled() { return cancelled(&report, staging: staging) }

        // Move into place, never over anything. From here the run goes on to the end.
        pointOfNoReturn()
        for file in staged {
            let outcome = merge(file, from: staging)
            report.entries.append(entry(file, outcome))
            do { try checkpoint(.merged(file.category, file.name)) }
            catch { report.state = .failed("interrupted"); return report }
        }
        report.entries.sort { ($0.category.rawValue, $0.name) < ($1.category.rawValue, $1.name) }

        guard report.failures.isEmpty else {
            try? fileManager.removeItem(at: staging)
            report.state = .incomplete
            return report
        }

        // A folder that could not be read is not accounted for: what was copied stays (it is identical the
        // next time), and no marker is written, so the copy is offered again.
        guard unreadable.isEmpty else {
            try? fileManager.removeItem(at: staging)
            report.state = .partial(unreadable: unreadable)
            return report
        }

        // Everything accounted for: look once more, then write the marker.
        for item in report.copied where !exists(destination(of: item), size: item.size) {
            try? fileManager.removeItem(at: staging)
            report.state = .failed("\(item.name) is not where it was moved to")
            return report
        }
        do { try checkpoint(.beforeMarker) } catch { report.state = .failed("interrupted"); return report }

        let marker = AppSupportMarker(
            version: AppSupportMarker.currentVersion, status: .completed,
            completedAt: ISO8601DateFormatter().string(from: now()), appVersion: appVersion, runId: runID,
            source: paths.legacyRoot.path, jsonLimitBytes: AppSupportScanner.jsonLimit,
            files: report.entries.map { .init(category: $0.category.rawValue, name: $0.name, size: $0.size, sha256: $0.sha256, outcome: Self.label($0.outcome)) },
            invalid: scan.invalidFiles.map { file in
                var reason = ""
                if case .invalid(let why) = file.verdict { reason = why.text }
                return .init(category: file.category.rawValue, name: file.name, reason: reason, sha256: file.sha256)
            },
            skippedCount: scan.skipped.count)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(marker).write(to: AppSupportMarker.url(in: paths.glossaRoot), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: staging)
            report.state = .failed("the marker could not be written: \(error.localizedDescription)")
            return report
        }
        try? fileManager.removeItem(at: staging)
        report.state = .completed
        return report
    }

    /// A stop at the caller's request, before anything was moved into place: our staging goes, no marker.
    private func cancelled(_ report: inout AppSupportMigrationReport, staging: URL) -> AppSupportMigrationReport {
        try? fileManager.removeItem(at: staging)
        report.entries = []
        report.state = .cancelled
        return report
    }

    // MARK: Staging

    /// Copies `file` into the staging folder and checks it. Returns why not, or nil when it is there and verified.
    /// Whether PageFlow's file is still what the scan hashed: a regular file of the same size and date.
    private func sourceIsAsScanned(_ file: AppSupportScannedFile) -> Bool {
        let source = paths.legacyDirectory(for: file.category).appendingPathComponent(file.name)
        guard let state = fileState(source), state.isRegular else { return false }
        return state.size == file.size && state.modified == file.modified
    }

    private func stage(_ file: AppSupportScannedFile, in staging: URL) -> String? {
        let source = paths.legacyDirectory(for: file.category).appendingPathComponent(file.name)
        guard let before = fileState(source), before.isRegular else { return "the source is gone or is no longer a regular file" }
        guard before.size == file.size, before.modified == file.modified else { return "the source changed after the scan" }

        let folder = staging.appendingPathComponent(file.category.folderName, isDirectory: true)
        let target = folder.appendingPathComponent(file.name)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
        } catch {
            return "the copy failed: \(error.localizedDescription)"
        }
        guard let copied = Self.sha256(of: target), copied == file.sha256 else { return "the copy does not match the source's SHA-256" }
        guard let after = fileState(source), after.isRegular, after.size == file.size, after.modified == file.modified else {
            return "the source changed while it was copied"
        }
        return nil
    }

    // MARK: Merge

    private func merge(_ file: AppSupportScannedFile, from staging: URL) -> AppSupportFileOutcome {
        let staged = staging.appendingPathComponent(file.category.folderName, isDirectory: true).appendingPathComponent(file.name)
        let folder = paths.directory(for: file.category)
        let target = folder.appendingPathComponent(file.name)
        do {
            if !fileManager.fileExists(atPath: folder.path) {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: file.category == .recovery ? [.posixPermissions: 0o700] : nil)
            }
        } catch {
            return .failed("the folder could not be created: \(error.localizedDescription)")
        }
        if let outcome = existingOutcome(at: target, for: file) { try? fileManager.removeItem(at: staged); return outcome }
        do {
            try fileManager.moveItem(at: staged, to: target)     // fails when the target exists: never replaces
            return .copied
        } catch {
            // Something appeared at the target since the look: judge that, do not replace it.
            if let outcome = existingOutcome(at: target, for: file) { try? fileManager.removeItem(at: staged); return outcome }
            return .failed("the file could not be moved into place: \(error.localizedDescription)")
        }
    }

    /// What Glossa's own file of this name means for `file`, or nil when there is none.
    private func existingOutcome(at target: URL, for file: AppSupportScannedFile) -> AppSupportFileOutcome? {
        guard let state = fileState(target) else { return nil }
        guard state.isRegular else { return .conflict("Glossa has something that is not a file at this name") }
        return Self.sha256(of: target) == file.sha256 ? .identical : .conflict("Glossa has a different file with this name")
    }

    // MARK: Helpers

    private func entry(_ file: AppSupportScannedFile, _ outcome: AppSupportFileOutcome) -> AppSupportMigrationEntry {
        .init(category: file.category, name: file.name, size: file.size, sha256: file.sha256 ?? "", outcome: outcome)
    }

    private func destination(of item: AppSupportMigrationEntry) -> URL {
        paths.directory(for: item.category).appendingPathComponent(item.name)
    }

    private func exists(_ url: URL, size: Int64) -> Bool {
        guard let state = fileState(url) else { return false }
        return state.isRegular && state.size == size
    }

    static func label(_ outcome: AppSupportFileOutcome) -> String {
        switch outcome {
        case .copied: return "copied"
        case .identical: return "identical"
        case .conflict: return "conflict"
        case .failed: return "failed"
        }
    }

    private enum MarkerState { case absent, valid(AppSupportMarker), invalid }

    private func readMarker() -> MarkerState {
        let url = AppSupportMarker.url(in: paths.glossaRoot)
        guard fileState(url) != nil else { return .absent }
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONDecoder().decode(AppSupportMarker.self, from: data),
              marker.version == AppSupportMarker.currentVersion, marker.status == .completed else { return .invalid }
        return .valid(marker)
    }

    /// Staging folders of earlier runs: real folders named `.import-staging-*` in Glossa's root.
    private func stagingFolders() -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: paths.glossaRoot.path)) ?? []
        return names.filter { $0.hasPrefix(Self.stagingPrefix) }
            .filter { fileState(paths.glossaRoot.appendingPathComponent($0))?.isDirectory == true }
            .sorted()
    }

    private func removeStagingFolders() {
        for name in stagingFolders() { try? fileManager.removeItem(at: paths.glossaRoot.appendingPathComponent(name)) }
    }

    /// Removes the staging folders left by earlier, cut-off runs. Only real folders named
    /// `.import-staging-*` directly inside Glossa's own folder: never a link, never anything of PageFlow's,
    /// and never once the copy is recorded as done (the marker is checked first). With `minimumAge`, a
    /// folder touched more recently than that (itself or its immediate subfolders, where a running copy
    /// writes) is left alone, in case another copy is running. Returns how many went.
    @discardableResult
    func removeOwnStaging(minimumAge: TimeInterval = 0, now: Date = Date()) -> Int {
        guard paths.legacyIsReachable else { return 0 }
        if case .absent = readMarker() {} else { return 0 }
        var removed = 0
        for name in stagingFolders() {
            let stagingURL = paths.glossaRoot.appendingPathComponent(name)
            if minimumAge > 0, now.timeIntervalSince(latestModification(of: stagingURL)) < minimumAge { continue }
            do { try fileManager.removeItem(at: stagingURL); removed += 1 } catch {}
        }
        return removed
    }

    /// The latest change time of a staging folder and of the folders directly in it.
    private func latestModification(of folder: URL) -> Date {
        var latest = fileState(folder)?.modified ?? .distantPast
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] {
            if let state = fileState(folder.appendingPathComponent(name)), state.isDirectory { latest = max(latest, state.modified) }
        }
        return latest
    }

    private func nearestExistingFolder(of url: URL) -> URL {
        var current = url
        while !fileManager.fileExists(atPath: current.path), current.pathComponents.count > 1 { current = current.deletingLastPathComponent() }
        return current
    }

    static func systemAvailableSpace(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return bytes
    }

    private struct FileState {
        var isRegular: Bool
        var isDirectory: Bool
        var size: Int64
        var modified: Date
    }

    /// What `url` itself is (a link is not followed); nil when there is nothing there.
    private func fileState(_ url: URL) -> FileState? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileState(isRegular: type == S_IFREG, isDirectory: type == S_IFDIR, size: Int64(info.st_size), modified: modified)
    }

    /// SHA-256 of a regular file, streamed; nil when it cannot be read.
    static func sha256(of url: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
