//
//  AppIdentity.swift
//  PageFlow
//
//  Who the app is, and who PageFlow was. The old identifier lives here and in the migration
//  code and nowhere else: it names the one place the old preferences are read from, never a
//  place anything is written to.
//

import Foundation
import Security

nonisolated enum AppIdentity {
    /// Glossa's own bundle identifier, and so the name of its preferences domain.
    static let bundleIdentifier = "io.github.effe1209.Glossa"
    /// PageFlow's. Read-only source of the import; the app never writes under it.
    static let legacyBundleIdentifier = "com.raccoontechnologies.PageFlow"

    /// Whether this process runs as Glossa. A development copy with another identifier (the
    /// QA harnesses) or a test host is not, and is never offered the import.
    static func isGlossa(_ bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Bool {
        bundleIdentifier == Self.bundleIdentifier
    }
}

/// Where the app keeps files under Application Support.
nonisolated enum ApplicationSupportLocations {
    static let glossaFolderName = "Glossa"
    static let legacyFolderName = "PageFlow"

    static func glossa(in base: URL) -> URL { base.appendingPathComponent(glossaFolderName, isDirectory: true) }
    static func legacy(in base: URL) -> URL { base.appendingPathComponent(legacyFolderName, isDirectory: true) }

    /// Creates Glossa's folder, empty, when it is not there. It does not look inside PageFlow's
    /// folder and copies nothing: Recovery, Attachments and EPUB Annotations are a separate step.
    @discardableResult
    static func prepareGlossaFolder(in base: URL, fileManager: FileManager = .default) -> Bool {
        let folder = glossa(in: base)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: folder.path, isDirectory: &isDirectory) { return isDirectory.boolValue }
        return (try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
    }
}

/// Whether the running copy is inside the macOS sandbox, read from its own entitlements.
nonisolated enum AppSandbox {
    static var isActive: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool == true
    }
}
