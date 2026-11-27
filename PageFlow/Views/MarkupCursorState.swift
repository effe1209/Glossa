//
//  MarkupCursorState.swift
//  PageFlow
//
//  Whether a markup tool's cursor is in force, so the app's own pointer
//  styles (the link hand on buttons) stand down instead of fighting it.
//

import SwiftUI

@MainActor
@Observable
final class MarkupCursorState {
    static let shared = MarkupCursorState()

    private(set) var isActive = false
    @ObservationIgnored private var owners = Set<ObjectIdentifier>()

    /// An owner that is going away can't be asked to switch off.
    func release(_ owner: ObjectIdentifier) {
        owners.remove(owner)
        let now = !owners.isEmpty
        if now != isActive { isActive = now }
    }

    func setActive(_ active: Bool, owner: AnyObject) {
        if active { owners.insert(ObjectIdentifier(owner)) } else { owners.remove(ObjectIdentifier(owner)) }
        let now = !owners.isEmpty
        if now != isActive { isActive = now }
    }
}
