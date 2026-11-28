//
//  AppSupportOffer.swift
//  PageFlow
//
//  Whether to offer the copy of PageFlow's Application Support files (unit B), and what to tell the
//  reader about it. Unit B is independent of the preferences (unit A): its own refusal record in
//  Glossa's preferences, its own marker file in Glossa's folder.
//
//  Deciding is cheap and reads no file's content: the folders are counted with `lstat` only (so the size
//  of the attachments is known before any file is opened, which is what the 500 MiB confirmation uses; it
//  is an upper bound, since it also counts files the scan may later find not sound). The files are hashed
//  and checked when the reader chooses Import, by `AppSupportMigrator`. A folder that is a symbolic link is
//  never followed: if that leaves nothing to offer, the reason says so (`legacyFolderIsLink`). A sandboxed build is
//  told apart before anything is looked at: PageFlow's folder is not read at all.
//

import Foundation

/// The reader's standing refusal of the file copy. Not A's record, and not B's marker.
nonisolated struct AppSupportDeclined: Codable, Equatable, Sendable {
    static let key = "glossa.migration.appSupport.declined.v1"
    static let currentVersion = 1

    var version: Int
    var decidedAt: String
    var appVersion: String
}

nonisolated enum FilesUnavailableReason: Equatable, Sendable {
    /// Not running as Glossa under its own identifier.
    case notGlossa
    /// A sandboxed build cannot reach PageFlow's folder, so the files cannot be copied.
    case sandboxed
    /// A valid marker is there: copied already.
    case alreadyCopied
    /// The reader chose "Don't Import Ever" for the files.
    case declined
    /// The reader chose "Don't Import Ever" for the preferences: the files are not offered either.
    case preferencesDeclined
    /// A marker file that is not valid is in the way; it is not overwritten.
    case markerInvalid
    /// PageFlow left no files in these folders.
    case nothingToCopy
    /// PageFlow's folder, or each folder that would hold files, is a symbolic link. Links are never followed,
    /// so nothing behind them is read or copied, and the reader is told why instead of "nothing to copy".
    case legacyFolderIsLink
    /// PageFlow's folder, or a folder of one of the three kinds, exists but cannot be read (permissions,
    /// a failed listing). Told apart from "nothing there", so the reader knows something is missing.
    case legacyFolderUnreadable

    var explanation: String {
        switch self {
        case .notGlossa: return "Copying files is only offered to Glossa under its own bundle identifier."
        case .sandboxed:
            return "This build of Glossa runs inside the macOS sandbox, which does not allow it to read PageFlow's folder, so it cannot copy PageFlow's recovery copies, attachments or EPUB annotations. The direct build (Release-Direct) can."
        case .alreadyCopied: return "PageFlow's files were already copied."
        case .declined: return "You chose not to copy PageFlow's files. Nothing was copied and PageFlow's folder was not touched."
        case .preferencesDeclined: return "You chose not to import anything from PageFlow, so its files are not offered either."
        case .markerInvalid: return "A record of an earlier copy is in Glossa's folder but cannot be read, so Glossa will not copy over it."
        case .nothingToCopy: return "PageFlow has no recovery copies, attachments or EPUB annotations to copy."
        case .legacyFolderUnreadable:
            return "Glossa could not read PageFlow's folder (or the folder of its recovery copies, attachments or EPUB annotations), so it cannot tell what is in it and copied nothing from there. Check that your user can open ~/Library/Application Support/PageFlow, then start Glossa again."
        case .legacyFolderIsLink:
            return "PageFlow's folder (or the folders of its recovery copies, attachments and EPUB annotations) is a link to somewhere else. Glossa does not follow links, so it copied nothing from there. If those files are yours, copy them into Glossa's folders yourself."
        }
    }
}

nonisolated struct FilesOffer: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var category: ApplicationSupportPaths.Category
        var files: Int
        var bytes: Int64
    }

    var lines: [Line]
    /// Folders that exist but could not be read: nothing from them is offered, and the window says so.
    var unreadable: [ApplicationSupportPaths.Category] = []
    /// An earlier copy was cut off: this offer starts it again from the beginning.
    var interrupted: Bool

    var totalFiles: Int { lines.reduce(0) { $0 + $1.files } }
    var totalBytes: Int64 { lines.reduce(0) { $0 + $1.bytes } }
    var attachmentBytes: Int64 { lines.first { $0.category == .attachments }?.bytes ?? 0 }
}

nonisolated enum FilesAvailability: Equatable, Sendable {
    case offer(FilesOffer)
    case unavailable(FilesUnavailableReason)

    var offer: FilesOffer? { if case .offer(let offer) = self { return offer } else { return nil } }
}

/// Counts what is in PageFlow's folders without opening anything: regular, visible files only.
nonisolated struct AppSupportCandidates {
    var paths: ApplicationSupportPaths
    var fileManager: FileManager = .default

    func lines() -> [FilesOffer.Line] {
        guard Self.isFolder(paths.legacyRoot) else { return [] }   // a missing folder, or a link: not followed
        return ApplicationSupportPaths.Category.allCases.compactMap { category in
            let folder = paths.legacyDirectory(for: category)
            guard Self.isFolder(folder) else { return nil }
            var files = 0
            var bytes: Int64 = 0
            for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where !name.hasPrefix(".") {
                var info = stat()
                guard lstat(folder.appendingPathComponent(name).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                files += 1
                bytes += Int64(info.st_size)
            }
            return files > 0 ? FilesOffer.Line(category: category, files: files, bytes: bytes) : nil
        }
    }

    /// The folders of the three kinds that exist but cannot be read: `lstat` fails for a reason other than
    /// "not there", or the listing fails. A folder that is missing, empty or a link is not in this list. When
    /// PageFlow's own folder cannot be looked into, all three are unreadable.
    func unreadableFolders() -> [ApplicationSupportPaths.Category] {
        switch Self.look(at: paths.legacyRoot) {
        case .missing, .link, .other: return []
        case .unreadable: return ApplicationSupportPaths.Category.allCases
        case .folder: break
        }
        return ApplicationSupportPaths.Category.allCases.filter { category in
            let folder = paths.legacyDirectory(for: category)
            switch Self.look(at: folder) {
            case .unreadable: return true
            case .folder: return (try? fileManager.contentsOfDirectory(atPath: folder.path)) == nil
            case .missing, .link, .other: return false
            }
        }
    }

    private enum Look { case missing, folder, link, other, unreadable }

    private static func look(at url: URL) -> Look {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .folder
        case S_IFLNK: return .link
        default: return .other
        }
    }

    /// True when PageFlow's folder, or a folder of one of the three kinds, is a symbolic link. Looked at with
    /// `lstat` only: the link is not followed and nothing behind it is read.
    func hasLinkedFolder() -> Bool {
        if Self.isLink(paths.legacyRoot) { return true }
        guard Self.isFolder(paths.legacyRoot) else { return false }
        return ApplicationSupportPaths.Category.allCases.contains { Self.isLink(paths.legacyDirectory(for: $0)) }
    }

    private static func isLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    private static func isFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }
}
