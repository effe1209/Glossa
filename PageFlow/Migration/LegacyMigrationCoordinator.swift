//
//  LegacyMigrationCoordinator.swift
//  PageFlow
//
//  Decides whether to offer the import from PageFlow, and carries out the reader's choice.
//  It is the only code that runs the engine for real (`dryRun: false`), and it does so only
//  for `.importNow`, which only a button the reader pressed produces.
//
//  Three choices, kept apart:
//    importNow    runs the import; the marker is written last, only on success.
//    notNow       writes nothing at all: the offer comes back at the next launch.
//    neverImport  writes a decision record and nothing else: no import, and no offer again.
//
//  The old preferences are read through the source, a read-only snapshot. This type never
//  opens PageFlow's domain for writing and never opens it as a UserDefaults suite.
//

import Foundation

nonisolated enum MigrationChoice: String, Sendable, CaseIterable {
    case importNow
    case notNow
    case neverImport
}

/// The reader's standing refusal, kept in Glossa's preferences. Distinct from the completion marker.
nonisolated struct MigrationDeclined: Codable, Equatable, Sendable {
    static let key = "glossa.migration.fromPageFlow.declined.v1"
    static let currentVersion = 1

    var version: Int
    var decidedAt: String
    var appVersion: String
}

nonisolated enum MigrationOffer: Equatable, Sendable {
    /// Ask the reader. `summary` is what an import would do, from a dry run.
    case offer(MigrationSummary)
    case notNeeded(Reason)

    enum Reason: Equatable, Sendable {
        /// Not running as Glossa (a test host, a QA copy): never offered.
        case notGlossa
        /// A completed import is recorded.
        case alreadyMigrated
        /// The reader chose "never".
        case declined
        /// A sandboxed build cannot read another app's preferences, so it cannot tell whether PageFlow
        /// left any, and importing is not available in it. The entitlements are not changed to get around this.
        case sandboxed
        /// PageFlow left no preferences that can be read here.
        case noLegacyData
        /// The old preferences cannot be read (a sandbox, a damaged file): nothing is offered.
        case sourceUnreadable(String)
        /// There is old data, but nothing in it would be written (it is all excluded, or Glossa already has it).
        case nothingToImport
    }

    var summary: MigrationSummary? { if case .offer(let summary) = self { return summary } else { return nil } }
}

nonisolated enum MigrationOutcome: Equatable, Sendable {
    /// "Not now": nothing was written.
    case postponed
    /// "Never": the decision was recorded.
    case declinedForGood
    /// The import ran (or was already done); the report says what happened.
    case imported(MigrationReport)
    /// A choice could not be carried out; nothing is recorded as done.
    case failed(String)
}

nonisolated struct LegacyMigrationCoordinator {
    var source: LegacyPreferencesSource
    var destination: MigrationDestination
    var migrator = LegacyMigrator()
    /// Whether this process is Glossa under its own identifier.
    var isGlossa: Bool = AppIdentity.isGlossa()
    /// Whether this copy runs in the macOS sandbox, which keeps it from reading PageFlow's preferences.
    var isSandboxed: Bool = AppSandbox.isActive
    var sourceDomain = AppIdentity.legacyBundleIdentifier
    var appVersion = ""
    /// Where Glossa's folder is prepared after a successful import (Application Support); nil to skip.
    var applicationSupport: URL?

    /// Reads, never writes: a dry run of the engine and two lookups in the destination.
    func evaluate() -> MigrationOffer {
        guard isGlossa else { return .notNeeded(.notGlossa) }
        if destination.value(forKey: MigrationMarker.key) != nil { return .notNeeded(.alreadyMigrated) }
        if destination.value(forKey: MigrationDeclined.key) != nil { return .notNeeded(.declined) }
        if isSandboxed { return .notNeeded(.sandboxed) }

        let snapshot: [String: Any]
        do { snapshot = try source.snapshot() }
        catch { return .notNeeded(.sourceUnreadable(error.localizedDescription)) }
        if snapshot.isEmpty { return .notNeeded(.noLegacyData) }

        let report = migrator.run(source: DictionarySource(values: snapshot), destination: destination, dryRun: true,
                                  sourceDomain: sourceDomain, appVersion: appVersion)
        let summary = MigrationSummary(report)
        return summary.hasAnythingToImport ? .offer(summary) : .notNeeded(.nothingToImport)
    }

    /// Whether a completed import is on record in `store` with every key it says it wrote. The app
    /// asks this of a fresh read of its preferences before restarting, so it never restarts on an
    /// import that is not there.
    static func importIsRecorded(in store: MigrationDestination) -> Bool {
        guard let data = store.value(forKey: MigrationMarker.key) as? Data,
              let marker = try? JSONDecoder().decode(MigrationMarker.self, from: data),
              marker.status == .completed else { return false }
        return marker.imported.allSatisfy { store.value(forKey: $0) != nil }
    }

    func choose(_ choice: MigrationChoice, now: Date = Date()) -> MigrationOutcome {
        switch choice {
        case .notNow:
            return .postponed
        case .neverImport:
            let record = MigrationDeclined(version: MigrationDeclined.currentVersion,
                                           decidedAt: ISO8601DateFormatter().string(from: now), appVersion: appVersion)
            do {
                try destination.set(try JSONEncoder().encode(record), forKey: MigrationDeclined.key)
                return .declinedForGood
            } catch {
                return .failed("the decision could not be saved: \(error.localizedDescription)")
            }
        case .importNow:
            // Same guards as `evaluate()`: a stale window cannot import for a refused or finished case.
            guard isGlossa else { return .failed("not running as Glossa") }
            guard !isSandboxed else { return .failed(MigrationOffer.Reason.sandboxed.explanation) }
            let report = migrator.run(source: source, destination: destination, dryRun: false,
                                      sourceDomain: sourceDomain, appVersion: appVersion, now: now)
            switch report.state {
            case .failed(let reason):
                return .failed(reason)
            case .applied:
                if let applicationSupport { ApplicationSupportLocations.prepareGlossaFolder(in: applicationSupport) }
                return .imported(report)
            case .alreadyMigrated, .dryRun:
                return .imported(report)
            }
        }
    }
}

nonisolated extension MigrationOffer.Reason {
    /// What to tell the reader when they ask for the import and it is not available, and why.
    var explanation: String {
        switch self {
        case .sandboxed:
            return "This build of Glossa runs inside the macOS sandbox, which does not allow it to read PageFlow's settings, so it cannot import them. The direct build (Release-Direct) is not sandboxed and can."
        case .notGlossa:
            return "Importing is only offered to Glossa under its own bundle identifier."
        case .alreadyMigrated:
            return "PageFlow's data was already imported."
        case .declined:
            return "You chose not to import PageFlow's data. Nothing was imported and PageFlow's data was not touched."
        case .noLegacyData:
            return "No PageFlow settings were found on this Mac."
        case .sourceUnreadable(let detail):
            return "PageFlow's settings could not be read: \(detail)"
        case .nothingToImport:
            return "PageFlow's data has nothing that Glossa would import: what it holds is left out on purpose or Glossa already has it."
        }
    }
}
