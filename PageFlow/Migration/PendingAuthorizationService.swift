//
//  PendingAuthorizationService.swift
//  PageFlow
//
//  One attempt to allow a pending file or folder again, with everything that touches the screen
//  or the stores passed in. The rules live here, where they can be tested:
//    - an access that is already valid is not asked for again (the entry just leaves the list);
//    - the reader's cancelling changes nothing;
//    - a different file than the one named changes nothing;
//    - the entry leaves the list only after the new access has been stored and verified.
//

import Foundation

nonisolated enum AuthorizationPick: Equatable, Sendable {
    case chosen(URL)
    case cancelled
}

nonisolated enum AuthorizationAttempt: Equatable, Sendable {
    /// Access already worked: nothing was asked, the entry is off the list.
    case alreadyAuthorized
    /// A new access was stored, verified, and the entry is off the list.
    case granted
    /// The reader cancelled the panel: nothing changed.
    case cancelled
    /// What was chosen is not what the entry names: nothing changed.
    case wrongSelection(expected: String)
    /// Stored, but it does not give access: the entry stays on the list.
    case notVerified
}

nonisolated struct PendingAuthorizationService {
    var destination: MigrationDestination
    /// Whether this entry already has a working access.
    var isAlreadyAuthorized: (PendingAuthorization) -> Bool
    /// Asks the reader, through the standard open panel. The only place access is requested.
    var pick: (PendingAuthorization) -> AuthorizationPick
    /// Stores the access the reader gave (a folder grant, a recent file's bookmark).
    var grant: (PendingAuthorization, URL) -> Void
    /// Whether `url` can now really be opened with what was stored.
    var verify: (PendingAuthorization, URL) -> Bool

    func list() -> [PendingAuthorization] { PendingAuthorizationList.read(from: destination) }

    func attempt(_ item: PendingAuthorization) -> AuthorizationAttempt {
        if isAlreadyAuthorized(item) {
            try? PendingAuthorizationList.resolve(store: item.store, path: item.path, in: destination)
            return .alreadyAuthorized
        }
        guard case .chosen(let url) = pick(item) else { return .cancelled }
        guard Self.matches(item, chosen: url) else {
            return .wrongSelection(expected: URL(fileURLWithPath: item.path).lastPathComponent)
        }
        grant(item, url)
        guard verify(item, url) else { return .notVerified }
        do { try PendingAuthorizationList.resolve(store: item.store, path: item.path, in: destination) }
        catch { return .notVerified }
        return .granted
    }

    /// A file has to be the one named; a folder may be the one named or one that contains it.
    static func matches(_ item: PendingAuthorization, chosen: URL) -> Bool {
        let wanted = URL(fileURLWithPath: item.path).standardizedFileURL.path
        let got = chosen.standardizedFileURL.path
        if got == wanted { return true }
        return item.isFolder && wanted.hasPrefix(got.hasSuffix("/") ? got : got + "/")
    }
}
