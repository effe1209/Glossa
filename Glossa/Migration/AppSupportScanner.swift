//
//  AppSupportScanner.swift
//  Glossa
//
//  Looks through PageFlow's Recovery, Attachments and EPUB Annotations folders and says what is
//  in them and whether each file is sound. Reading only: it creates, copies, renames, changes and
//  deletes nothing, writes no marker and no preference. The copy runs it when the reader chooses
//  Import, and it can be stopped between files and chunks (`isCancelled`).
//
//  What it looks at, per folder:
//    - regular files, examined: hashed (SHA-256, streamed) and checked against what the app would
//      later read them as;
//    - everything else (symbolic links, hidden files, subfolders, special files) is listed as
//      skipped and never opened, followed or hashed.
//  A file that does not check out is reported as invalid, with the reason; it does not stop the
//  scan. Nothing is copied on the strength of existing: only a file reported valid can be.
//
//  A sandboxed build cannot reach PageFlow's folder (`ApplicationSupportPaths.legacyIsReachable`),
//  so it scans nothing.
//

import CryptoKit
import Foundation
import ImageIO

// MARK: - Report

nonisolated enum AppSupportSkipReason: String, Sendable {
    case symbolicLink
    case hidden
    case subfolder
    /// A socket, a device, a fifo.
    case notARegularFile
}

nonisolated enum AppSupportInvalidReason: Equatable, Sendable {
    case unreadable(String)
    case empty
    case tooLarge
    case notJSON
    /// JSON that is not what the app stores (a field missing or of the wrong type).
    case wrongStructure(String)
    /// The file's name is not the one the app would give it, so the app would never find it.
    case nameDoesNotMatchContent
    case notAnImage(String)
}

nonisolated enum AppSupportVerdict: Equatable, Sendable {
    case valid
    case invalid(AppSupportInvalidReason)

    var isValid: Bool { self == .valid }
}

nonisolated struct AppSupportScannedFile: Equatable, Sendable {
    var category: ApplicationSupportPaths.Category
    var name: String
    var size: Int64
    var modified: Date
    /// Lowercase hex SHA-256 of the whole file; nil only when it could not be read.
    var sha256: String?
    var verdict: AppSupportVerdict
}

nonisolated struct AppSupportSkippedEntry: Equatable, Sendable {
    var category: ApplicationSupportPaths.Category
    var name: String
    var reason: AppSupportSkipReason
}

nonisolated struct AppSupportCategoryReport: Equatable, Sendable {
    enum FolderState: Equatable, Sendable {
        /// Not there: nothing to scan, and not an error.
        case missing
        /// Scanned.
        case present
        /// A symbolic link, or a file where a folder should be: not followed, not scanned.
        case notAFolder
        case unreadable(String)
    }

    var category: ApplicationSupportPaths.Category
    var folder: URL
    var state: FolderState
    var files: [AppSupportScannedFile] = []
    var skipped: [AppSupportSkippedEntry] = []

    var validFiles: [AppSupportScannedFile] { files.filter { $0.verdict.isValid } }
    var invalidFiles: [AppSupportScannedFile] { files.filter { !$0.verdict.isValid } }
    var validBytes: Int64 { validFiles.reduce(0) { $0 + $1.size } }
}

nonisolated struct AppSupportScanReport: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// The folders were looked at (some may be missing).
        case scanned
        /// A sandboxed build: PageFlow's folder is out of reach, nothing was looked at.
        case legacyUnreachable
        /// PageFlow's folder is a link, or not a folder: not followed, nothing scanned.
        case rootNotAFolder
    }

    var state: State
    var categories: [AppSupportCategoryReport] = []

    func report(for category: ApplicationSupportPaths.Category) -> AppSupportCategoryReport? {
        categories.first { $0.category == category }
    }

    var validFiles: [AppSupportScannedFile] { categories.flatMap(\.validFiles) }
    var invalidFiles: [AppSupportScannedFile] { categories.flatMap(\.invalidFiles) }
    var skipped: [AppSupportSkippedEntry] { categories.flatMap(\.skipped) }
    var validBytes: Int64 { categories.reduce(0) { $0 + $1.validBytes } }
    /// Whether anything valid is there to copy.
    var hasAnythingToCopy: Bool { !validFiles.isEmpty }
}

// MARK: - Scanner

nonisolated struct AppSupportScanner {
    var paths: ApplicationSupportPaths
    var fileManager: FileManager = .default
    /// Asked between files and between chunks of a file; true stops the scan, which then returns what it had.
    /// The caller that sets it discards such a report.
    var isCancelled: () -> Bool = { false }

    /// Files larger than this are not read into memory to be checked as JSON.
    static let jsonLimit = 64 * 1024 * 1024
    private static let chunkSize = 1024 * 1024

    func scan() -> AppSupportScanReport {
        guard paths.legacyIsReachable else { return AppSupportScanReport(state: .legacyUnreachable) }

        // PageFlow's folder itself: missing is fine, a link or a file is not followed.
        switch kind(of: paths.legacyRoot) {
        case .none:
            return AppSupportScanReport(state: .scanned, categories: ApplicationSupportPaths.Category.allCases.map {
                AppSupportCategoryReport(category: $0, folder: paths.legacyDirectory(for: $0), state: .missing)
            })
        case .folder: break
        case .other: return AppSupportScanReport(state: .rootNotAFolder)
        }

        return AppSupportScanReport(state: .scanned,
                                    categories: ApplicationSupportPaths.Category.allCases.map(scan(_:)))
    }

    // MARK: A folder

    private func scan(_ category: ApplicationSupportPaths.Category) -> AppSupportCategoryReport {
        let folder = paths.legacyDirectory(for: category)
        var report = AppSupportCategoryReport(category: category, folder: folder, state: .present)
        switch kind(of: folder) {
        case .none: report.state = .missing; return report
        case .other: report.state = .notAFolder; return report
        case .folder: break
        }

        let names: [String]
        do { names = try fileManager.contentsOfDirectory(atPath: folder.path).sorted() }
        catch { report.state = .unreadable(error.localizedDescription); return report }

        for name in names {
            if isCancelled() { break }
            let url = folder.appendingPathComponent(name)
            guard let info = lstatInfo(url) else { continue }   // gone since the listing
            let type = info.mode & S_IFMT
            if type == S_IFLNK { report.skipped.append(.init(category: category, name: name, reason: .symbolicLink)); continue }
            if name.hasPrefix(".") { report.skipped.append(.init(category: category, name: name, reason: .hidden)); continue }
            if type == S_IFDIR { report.skipped.append(.init(category: category, name: name, reason: .subfolder)); continue }
            if type != S_IFREG { report.skipped.append(.init(category: category, name: name, reason: .notARegularFile)); continue }
            report.files.append(examine(url, name: name, category: category))
        }
        return report
    }

    // MARK: A file

    private func examine(_ url: URL, name: String, category: ApplicationSupportPaths.Category) -> AppSupportScannedFile {
        var file = AppSupportScannedFile(category: category, name: name, size: 0, modified: .distantPast, sha256: nil, verdict: .valid)
        // Opened without following a link that appeared since the listing, and read-only.
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            file.verdict = .invalid(.unreadable(String(cString: strerror(errno))))
            return file
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            file.verdict = .invalid(.unreadable("not a regular file"))
            return file
        }
        file.size = Int64(info.st_size)
        file.modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)

        let keepsContent = category != .attachments && file.size <= Int64(Self.jsonLimit)
        var hasher = SHA256()
        var content = Data()
        do {
            while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
                if isCancelled() { file.verdict = .invalid(.unreadable("cancelled")); return file }
                hasher.update(data: chunk)
                if keepsContent { content.append(chunk) }
            }
        } catch {
            file.verdict = .invalid(.unreadable(error.localizedDescription))
            return file
        }
        file.sha256 = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        if file.size == 0 { file.verdict = .invalid(.empty); return file }
        switch category {
        case .recovery:
            file.verdict = keepsContent ? Self.checkRecovery(content, name: name) : .invalid(.tooLarge)
        case .epubAnnotations:
            file.verdict = keepsContent ? Self.checkAnnotations(content, name: name) : .invalid(.tooLarge)
        case .attachments:
            file.verdict = Self.checkImage(at: url, handle: handle, size: file.size)
        }
        return file
    }

    // MARK: Validation

    /// What `MarkdownRecoveryStore.Record` stores. Its file is named after the record's id.
    private struct RecoveryShape: Decodable {
        var id: UUID
        var title: String
        var originalURL: URL?
        var source: String
        var commentBlock: String?
        var updatedAt: Date
    }

    static func checkRecovery(_ data: Data, name: String) -> AppSupportVerdict {
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return .invalid(.notJSON) }
        let record: RecoveryShape
        do { record = try JSONDecoder().decode(RecoveryShape.self, from: data) }
        catch { return .invalid(.wrongStructure("not a recovery copy")) }
        return name == record.id.uuidString + ".json" ? .valid : .invalid(.nameDoesNotMatchContent)
    }

    /// What `EPUBAnnotationStore` stores: an identifier (maybe null), a path, highlights, bookmarks, a date.
    /// The file is named by the SHA-256 of `id:<identifier>` or `path:<path>`.
    static func checkAnnotations(_ data: Data, name: String) -> AppSupportVerdict {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return .invalid(.notJSON) }
        guard let record = object as? [String: Any] else { return .invalid(.wrongStructure("not an object")) }
        guard let path = record["path"] as? String else { return .invalid(.wrongStructure("path")) }
        guard record["highlights"] is [Any] else { return .invalid(.wrongStructure("highlights")) }
        guard record["bookmarks"] is [Any] else { return .invalid(.wrongStructure("bookmarks")) }
        guard record["updatedAt"] is NSNumber else { return .invalid(.wrongStructure("updatedAt")) }
        let identifier: String?
        switch record["identifier"] {
        case nil, is NSNull: identifier = nil
        case let string as String: identifier = string
        default: return .invalid(.wrongStructure("identifier"))
        }
        func fileName(_ identity: String) -> String {
            SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
        }
        var accepted = [fileName("path:\(path)")]
        if let identifier { accepted.append(fileName("id:\(identifier)")) }
        return accepted.contains(name) ? .valid : .invalid(.nameDoesNotMatchContent)
    }

    /// An attachment has to open as an image and have at least one frame that decodes. ImageIO is
    /// lenient with a cut-off file, so a PNG (the format the app saves images in) is also walked chunk by
    /// chunk and has to reach its IEND chunk. Other formats rest on ImageIO's own verdict.
    static func checkImage(at url: URL, handle: FileHandle, size: Int64) -> AppSupportVerdict {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .invalid(.notAnImage("not recognised")) }
        guard CGImageSourceGetStatus(source) == .statusComplete else { return .invalid(.notAnImage("incomplete")) }
        guard CGImageSourceGetCount(source) > 0 else { return .invalid(.notAnImage("no image")) }
        guard CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return .invalid(.notAnImage("does not decode")) }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return .invalid(.notAnImage("truncated")) }
        if pngIsCutOff(handle, size: size) { return .invalid(.notAnImage("truncated")) }
        return .valid
    }

    /// True when the file is a PNG whose chunks do not reach IEND inside the file.
    private static func pngIsCutOff(_ handle: FileHandle, size: Int64) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        do {
            try handle.seek(toOffset: 0)
            guard let head = try handle.read(upToCount: 8), Array(head) == signature else { return false }   // not a PNG
            var offset: Int64 = 8
            while offset + 8 <= size {
                try handle.seek(toOffset: UInt64(offset))
                guard let header = try handle.read(upToCount: 8), header.count == 8 else { return true }
                let length = header.prefix(4).reduce(Int64(0)) { $0 << 8 | Int64($1) }
                if header.suffix(4) == Data("IEND".utf8) { return offset + 12 > size }
                offset += 12 + length          // length, type, data, CRC
            }
            return true
        } catch {
            return true
        }
    }

    // MARK: lstat

    private enum Kind { case none, folder, other }

    /// What `url` is itself, never what a link points at.
    private func kind(of url: URL) -> Kind {
        guard let info = lstatInfo(url) else { return .none }
        return info.mode & S_IFMT == S_IFDIR ? .folder : .other
    }

    private func lstatInfo(_ url: URL) -> (mode: mode_t, size: Int64)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return (info.st_mode, Int64(info.st_size))
    }
}
