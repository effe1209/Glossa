//
//  LegacyMigrator.swift
//  Glossa
//
//  Copies the allowed part of PageFlow's preferences into Glossa's, once. Not wired to
//  the app's launch: only LegacyMigrationCoordinator runs it, when the reader chooses Import.
//
//  The source is read-only by construction: it can only produce a snapshot. The
//  destination wins: a key that already has a value is left as it is. The marker is
//  written last and only when everything before it was written; if anything fails,
//  the keys this run wrote are taken back and there is no marker, so the next run
//  starts clean. A dry run reads the source and the destination and writes nothing.
//

import Foundation

// MARK: - Source

/// Where the old preferences are read from: a snapshot, never a handle that can write.
nonisolated protocol LegacyPreferencesSource {
    func snapshot() throws -> [String: Any]
}

nonisolated struct DictionarySource: LegacyPreferencesSource {
    var values: [String: Any]
    func snapshot() throws -> [String: Any] { values }
}

/// A preferences property list on disk, read and never written. It is how a sandboxed build
/// would read PageFlow's file after the reader picks it.
nonisolated struct PropertyListFileSource: LegacyPreferencesSource {
    var url: URL
    func snapshot() throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return dictionary
    }
}

/// An application's preferences domain, read through CFPreferences' copy calls only.
nonisolated struct CFPreferencesDomainSource: LegacyPreferencesSource {
    var domain: String
    func snapshot() throws -> [String: Any] {
        guard let keys = CFPreferencesCopyKeyList(domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String],
              !keys.isEmpty else { return [:] }
        return CFPreferencesCopyMultiple(keys as CFArray, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }
}

// MARK: - Destination

nonisolated protocol MigrationDestination {
    func value(forKey key: String) -> Any?
    func set(_ value: Any, forKey key: String) throws
    func remove(forKey key: String) throws
}

nonisolated struct UserDefaultsDestination: MigrationDestination {
    var defaults: UserDefaults
    func value(forKey key: String) -> Any? { defaults.object(forKey: key) }
    func set(_ value: Any, forKey key: String) throws { defaults.set(value, forKey: key) }
    func remove(forKey key: String) throws { defaults.removeObject(forKey: key) }
}

// MARK: - Marker

nonisolated struct MigrationMarker: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case completed }

    static let key = "glossa.migration.fromPageFlow.v1"
    static let currentVersion = 1

    var version: Int
    var status: Status
    var completedAt: String
    var sourceDomain: String
    var appVersion: String
    /// The destination keys this import wrote: what an undo would take back.
    var imported: [String]
}

// MARK: - Migrator

nonisolated struct LegacyMigrator {
    static let legacyDomain = "com.raccoontechnologies.PageFlow"

    var planner = LegacyMigrationPlanner()

    struct Failure: Error { var reason: String }

    /// Plans the import and, unless `dryRun`, carries it out.
    func run(source: LegacyPreferencesSource, destination: MigrationDestination, dryRun: Bool,
             sourceDomain: String = LegacyMigrator.legacyDomain, appVersion: String = "", now: Date = Date()) -> MigrationReport {
        // An earlier import, completed (or a marker from a version this one does not know): nothing to do.
        if destination.value(forKey: MigrationMarker.key) != nil {
            return MigrationReport(state: .alreadyMigrated)
        }

        let snapshot: [String: Any]
        do { snapshot = try source.snapshot() }
        catch { return MigrationReport(state: .failed("the source could not be read: \(error.localizedDescription)")) }

        let plan = planner.plan(source: snapshot)
        var report = MigrationReport(state: dryRun ? .dryRun : .applied, items: plan.items, bookmarkFindings: plan.findings)

        // The destination wins.
        var toWrite: [LegacyMigrationPlanner.Planned] = []
        for planned in plan.writes {
            if destination.value(forKey: planned.destinationKey) != nil { report.keptFromDestination.append(planned.destinationKey) }
            else { toWrite.append(planned) }
        }
        if dryRun { return report }

        var written: [String] = []
        do {
            for planned in toWrite {
                try destination.set(planned.value, forKey: planned.destinationKey)
                written.append(planned.destinationKey)
            }
            // What could not carry its access over is kept, with its path, until the reader allows it again.
            let pending = PendingAuthorizationList.make(from: plan.findings)
            if !pending.isEmpty, destination.value(forKey: PendingAuthorizationList.key) == nil {
                try destination.set(try PendingAuthorizationList.encode(pending), forKey: PendingAuthorizationList.key)
                written.append(PendingAuthorizationList.key)
            }
            let marker = MigrationMarker(version: MigrationMarker.currentVersion, status: .completed,
                                         completedAt: ISO8601DateFormatter().string(from: now),
                                         sourceDomain: sourceDomain, appVersion: appVersion, imported: written)
            try destination.set(try JSONEncoder().encode(marker), forKey: MigrationMarker.key)
        } catch {
            // Take back what this run wrote; the marker was never written.
            for key in written { try? destination.remove(forKey: key) }
            return MigrationReport(state: .failed(String(describing: error)), items: plan.items, bookmarkFindings: plan.findings,
                                   written: [], keptFromDestination: report.keptFromDestination)
        }
        report.written = written
        return report
    }
}
