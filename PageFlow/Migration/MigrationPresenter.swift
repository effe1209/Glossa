//
//  MigrationPresenter.swift
//  PageFlow
//
//  The app's one entry point to the import: it asks the coordinator whether to offer it and
//  shows the window if so. It never imports by itself; only the Import button does.
//
//  The stores (settings, recent files, the PDF library) read their preferences when the app
//  starts, so an import is followed by a restart: the window is modal until then, and nothing
//  can save over what was just imported. Permissions to allow again are asked after the restart,
//  from the list the import left in Glossa's preferences.
//

import AppKit
import SwiftUI

@MainActor
enum MigrationPresenter {
    private static var authorizationWindow: NSWindow?
    private static let authorizationPromptedKey = "glossa.migration.fromPageFlow.authorizationPrompted.v1"

    static func makeCoordinator(defaults: UserDefaults = AppDefaults.store) -> LegacyMigrationCoordinator {
        LegacyMigrationCoordinator(
            source: CFPreferencesDomainSource(domain: AppIdentity.legacyBundleIdentifier),
            destination: UserDefaultsDestination(defaults: defaults),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            applicationSupport: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
    }

    /// At launch: the offer if there is one, else the list of permissions to allow again, else nothing.
    /// Called before the previous session is restored, so no document is open and no store has anything
    /// to save while the window is up, and a restart after an import cannot write stale values over it.
    /// True when the app is restarting and the launch must not go on.
    static func presentIfNeeded(recentFiles: RecentFilesManager) -> Bool {
        PendingAuthorizationsModel.shared.configure(recentFiles: recentFiles)
        guard !TestEnvironment.isRunningTests, AppIdentity.isGlossa() else { return false }
        let coordinator = makeCoordinator()
        if let summary = coordinator.evaluate().summary {
            return runOffer(summary, coordinator: coordinator)
        }
        presentAuthorizations(coordinator: coordinator, recentFiles: recentFiles)
        return false
    }

    @discardableResult
    private static func runOffer(_ summary: MigrationSummary, coordinator: LegacyMigrationCoordinator) -> Bool {
        var relaunch = false
        var window: NSWindow?
        let model = MigrationViewModel(summary: summary, coordinator: coordinator) { wantsRelaunch in
            relaunch = wantsRelaunch
            NSApp.stopModal()
            window?.orderOut(nil)
        }
        let controller = NSHostingController(rootView: MigrationView(model: model))
        let panel = NSWindow(contentViewController: controller)
        panel.title = "Import from PageFlow"
        panel.styleMask = [.titled]
        panel.center()
        window = panel
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: panel)
        window = nil
        guard relaunch else { return false }
        restart(coordinator: coordinator)
        return true
    }

    /// The first launch after an import: the list, once. The paths stay in the list; the menu brings it back.
    private static func presentAuthorizations(coordinator: LegacyMigrationCoordinator, recentFiles: RecentFilesManager) {
        let destination = coordinator.destination
        PendingAuthorizationsModel.shared.refresh()
        guard destination.value(forKey: authorizationPromptedKey) == nil,
              !PendingAuthorizationsModel.shared.items.isEmpty else { return }
        try? destination.set(true, forKey: authorizationPromptedKey)
        showAuthorizationManager()
    }

    /// "Manage Authorizations to Restore…": the same window, whenever the reader wants it.
    static func showAuthorizationManager() {
        let model = PendingAuthorizationsModel.shared
        model.refresh()
        if let window = authorizationWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSWindow(contentViewController: NSHostingController(rootView: AuthorizationView(model: model) {
            authorizationWindow?.close()
            authorizationWindow = nil
        }))
        panel.title = "Allow Files and Folders"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()
        authorizationWindow = panel
        panel.makeKeyAndOrderFront(nil)
    }

    /// "Import from PageFlow…": says whether the import is available and, if not, why. It does not
    /// import: that is offered only at launch, before any document is open, because a running app holds
    /// copies of its preferences that it would write back over what was imported.
    static func importFromMenu() {
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        switch makeCoordinator().evaluate() {
        case .offer:
            alert.messageText = "PageFlow's data can be imported"
            alert.informativeText = "The import is offered when Glossa starts, before any document opens. Quit and open Glossa again to choose."
        case .notNeeded(let reason):
            alert.messageText = reason == .sandboxed ? "Importing is not available in this build" : "Nothing to import"
            alert.informativeText = reason.explanation
        }
        alert.runModal()
    }

    /// Restarts only once the import is read back from the preferences, marker and every key it wrote.
    /// If it cannot be confirmed the app quits without starting a new copy, and the import is not
    /// recorded as done: the next launch offers it again.
    private static func restart(coordinator: LegacyMigrationCoordinator) {
        let readback = PreferencesReadback(applicationID: AppIdentity.bundleIdentifier)
        guard LegacyMigrationCoordinator.importIsRecorded(in: readback) else {
            let alert = NSAlert()
            alert.messageText = "The import could not be confirmed"
            alert.informativeText = "Glossa could not read the imported data back from its preferences, so it will quit without restarting. Open Glossa again; the import will be offered again, and PageFlow's data was not touched."
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// A read-only look at Glossa's own preferences as the system holds them, after asking for them to be
/// written out: what a restarted app will find.
private struct PreferencesReadback: MigrationDestination {
    let applicationID: String
    init(applicationID: String) {
        self.applicationID = applicationID
        CFPreferencesAppSynchronize(applicationID as CFString)
    }
    func value(forKey key: String) -> Any? { CFPreferencesCopyAppValue(key as CFString, applicationID as CFString) }
    func set(_ value: Any, forKey key: String) throws { throw LegacyMigrator.Failure(reason: "read-only") }
    func remove(forKey key: String) throws { throw LegacyMigrator.Failure(reason: "read-only") }
}
