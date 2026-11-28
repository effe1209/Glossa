//
//  ApplicationSupportPaths.swift
//  Glossa
//
//  Every folder the app keeps under Application Support, in one place.
//
//  Two kinds of path, kept apart on purpose:
//    - Glossa's own (`glossaRoot`, `directory(for:)`): where the stores read and write.
//    - PageFlow's (`legacyRoot`, `legacyDirectory(for:)`): where the old data sits. Nothing in the
//      app reads or writes these in its ordinary work; they exist so that a later, explicit copy
//      can name its source.
//
//  The stores take their folder from `directory(for:)` only. There is no fallback from Glossa's
//  folder to PageFlow's: an empty Glossa folder is an empty Glossa folder.
//
//  `base` is the Application Support folder the system gives this process. Outside the sandbox that
//  is `~/Library/Application Support`; inside it, the container's own, where PageFlow's folder does
//  not exist and cannot be reached (`legacyIsReachable` says so). Tests pass a temporary folder.
//

import Foundation

nonisolated struct ApplicationSupportPaths: Equatable, Sendable {
    /// The three kinds of data kept in folders, each with the same name under Glossa and PageFlow.
    enum Category: String, CaseIterable, Sendable {
        case recovery
        case attachments
        case epubAnnotations

        /// The folder's name, the same in Glossa's root and in PageFlow's.
        var folderName: String {
            switch self {
            case .recovery: return "Recovery"
            case .attachments: return "Attachments"
            case .epubAnnotations: return "EPUB Annotations"
            }
        }
    }

    static let glossaFolderName = "Glossa"
    static let legacyFolderName = "PageFlow"

    /// The Application Support folder both roots sit in.
    let base: URL
    /// Whether PageFlow's folder can be reached from here. False in a sandboxed build, whose
    /// `base` is the container's: PageFlow's real folder is outside it and stays out of reach.
    let legacyIsReachable: Bool

    init(base: URL, legacyIsReachable: Bool = true) {
        self.base = base
        self.legacyIsReachable = legacyIsReachable
    }

    /// The paths of this process: the system's Application Support folder, or the temporary folder
    /// in the unlikely case the system gives none. Reading `AppSandbox` needs nothing from the folder.
    static func current(fileManager: FileManager = .default, isSandboxed: Bool = AppSandbox.isActive) -> ApplicationSupportPaths {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return ApplicationSupportPaths(base: base, legacyIsReachable: !isSandboxed)
    }

    // MARK: Glossa: what the stores use

    var glossaRoot: URL { base.appendingPathComponent(Self.glossaFolderName, isDirectory: true) }

    /// Where a store reads and writes `category`.
    func directory(for category: Category) -> URL {
        glossaRoot.appendingPathComponent(category.folderName, isDirectory: true)
    }

    var recovery: URL { directory(for: .recovery) }
    var attachments: URL { directory(for: .attachments) }
    var epubAnnotations: URL { directory(for: .epubAnnotations) }

    // MARK: PageFlow: the source of a later copy, and nothing else

    var legacyRoot: URL { base.appendingPathComponent(Self.legacyFolderName, isDirectory: true) }

    func legacyDirectory(for category: Category) -> URL {
        legacyRoot.appendingPathComponent(category.folderName, isDirectory: true)
    }
}
