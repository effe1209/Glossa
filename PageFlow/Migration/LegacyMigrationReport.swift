//
//  LegacyMigrationReport.swift
//  PageFlow
//
//  What an import from PageFlow's preferences would do, or did, key by key. The report
//  holds no values, only keys, kinds and reasons, so it is safe to show or log.
//
//  Nothing in `Migration/` is wired to the app's launch yet.
//

import Foundation

/// Where a key from the old preferences ends up.
nonisolated enum MigrationCategory: String, Sendable, CaseIterable {
    /// Copied as it is.
    case transferable
    /// Left behind on purpose (window state, a session, a key nobody listed).
    case excluded
    /// Not what it should be (the wrong type, malformed): not copied.
    case invalid
    /// Copied in part, or in a reduced form, and something about it needs the reader's
    /// attention (a bookmark that no longer proves access, an entry that is gone).
    case needsVerification
}

nonisolated struct MigrationItem: Equatable, Sendable {
    var sourceKey: String
    /// The key the value is written to; nil when nothing is.
    var destinationKey: String?
    var category: MigrationCategory
    var detail: String
}

/// One security-scoped bookmark, judged on its own.
nonisolated struct BookmarkFinding: Equatable, Sendable {
    enum Outcome: String, Sendable {
        /// Resolves, is current, and the file can be read.
        case valid
        /// Resolves, but the file moved: the bookmark no longer says where it is.
        case stale
        /// Does not resolve to anything.
        case unresolvable
        /// Resolves, but the file cannot be read with it.
        case unreachable
    }

    enum Action: String, Sendable {
        /// The bookmark is copied as it is.
        case kept
        /// The entry is copied with its path but without the bookmark.
        case keptWithoutBookmark
        /// The entry is not copied.
        case dropped
    }

    /// The key of the store the bookmark was in.
    var store: String
    /// The path (or document id) the entry names.
    var subject: String
    var outcome: Outcome
    var action: Action

    /// The reader has to grant access again before the entry can be read.
    var needsNewAuthorization: Bool { action != .kept }
}

nonisolated struct MigrationReport: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// Nothing was written anywhere.
        case dryRun
        /// Written, and the marker saved.
        case applied
        /// The marker was already there: nothing was done.
        case alreadyMigrated
        /// Stopped; whatever this run had written was taken back, and there is no marker.
        case failed(String)
    }

    var state: State
    var items: [MigrationItem] = []
    var bookmarkFindings: [BookmarkFinding] = []
    /// Destination keys this run wrote (empty for a dry run).
    var written: [String] = []
    /// Destination keys that already had a value, which wins and is left as it is.
    var keptFromDestination: [String] = []

    func items(_ category: MigrationCategory) -> [MigrationItem] { items.filter { $0.category == category } }

    var needsNewAuthorization: [BookmarkFinding] { bookmarkFindings.filter(\.needsNewAuthorization) }
}
