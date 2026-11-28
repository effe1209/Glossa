//
//  PendingAuthorization.swift
//  PageFlow
//
//  The files and folders an import could not carry access for. A bookmark made under PageFlow's
//  identity may not open anything under Glossa's, and an entry that is dropped would otherwise
//  take its path with it. This list keeps the path and what was found, in Glossa's own
//  preferences, until the reader allows each one again (or never does).
//
//  Nothing here creates access: a bookmark is made only when the reader picks the file or the
//  folder, and only then is the entry taken off the list.
//

import Foundation

nonisolated struct PendingAuthorization: Codable, Equatable, Sendable {
    /// The preferences key of the store the bookmark was in (in PageFlow's naming).
    var store: String
    /// The path the entry names; what the reader is asked to find again.
    var path: String
    /// `BookmarkFinding.Outcome.rawValue`.
    var outcome: String
    /// `BookmarkFinding.Action.rawValue`: whether the entry was kept without its bookmark or left out.
    var action: String

    init(_ finding: BookmarkFinding) {
        store = finding.store
        path = finding.subject
        outcome = finding.outcome.rawValue
        action = finding.action.rawValue
    }

    var isFolder: Bool { store == "folderAccessBookmarks.v1" }
}

nonisolated enum PendingAuthorizationList {
    static let key = "glossa.migration.fromPageFlow.pendingAuthorization.v1"

    static func make(from findings: [BookmarkFinding]) -> [PendingAuthorization] {
        findings.filter(\.needsNewAuthorization).map(PendingAuthorization.init)
    }

    static func encode(_ list: [PendingAuthorization]) throws -> Data { try JSONEncoder().encode(list) }

    static func read(from destination: MigrationDestination) -> [PendingAuthorization] {
        guard let data = destination.value(forKey: key) as? Data else { return [] }
        return (try? JSONDecoder().decode([PendingAuthorization].self, from: data)) ?? []
    }

    /// Takes one entry off the list once the reader has allowed it again.
    static func resolve(store: String, path: String, in destination: MigrationDestination) throws {
        var list = read(from: destination)
        let before = list.count
        list.removeAll { $0.store == store && $0.path == path }
        guard list.count != before else { return }
        if list.isEmpty { try destination.remove(forKey: key) } else { try destination.set(try encode(list), forKey: key) }
    }
}
