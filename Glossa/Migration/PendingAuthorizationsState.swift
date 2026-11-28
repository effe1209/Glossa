//
//  PendingAuthorizationsState.swift
//  Glossa
//
//  The list of permissions still to be allowed again, as something the interface can watch.
//  The menu item and the window both read `items`, so when the list changes (an entry is
//  resolved, the list is read again) they follow with no restart. The list itself lives in
//  Glossa's preferences; this only mirrors it.
//

import Foundation
import Observation

@Observable
final class PendingAuthorizationsState {
    private(set) var items: [PendingAuthorization]
    @ObservationIgnored private let destination: MigrationDestination

    init(destination: MigrationDestination) {
        self.destination = destination
        items = PendingAuthorizationList.read(from: destination)
    }

    var hasPending: Bool { !items.isEmpty }

    /// Reads the list again. Assigns only when it changed, so nothing watching is disturbed otherwise.
    func refresh() {
        let current = PendingAuthorizationList.read(from: destination)
        if current != items { items = current }
    }
}
