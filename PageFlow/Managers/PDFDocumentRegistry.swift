//
//  PDFDocumentRegistry.swift
//  PageFlow
//
//  What Glossa remembers about the PDFs it has opened or quoted, keyed by the
//  document's stable identity (`PDFDocumentFingerprint`) instead of its path:
//  a security-scoped bookmark (which follows the file when it is moved or
//  renamed, and carries the sandbox's permission to read it again), the last
//  path and title, and the notes that quote it. Nothing here copies or moves a
//  PDF; it only remembers where one is.
//
//  The same shape as `FolderAccessStore`: a thread-safe value in UserDefaults.
//

import Foundation

nonisolated struct PDFDocumentRecord: Codable, Equatable, Sendable {
    var id: String
    var title: String
    var lastPath: String
    var bookmark: Data?
    var updatedAt: Date
    var notes: [NoteEntry] = []

    struct NoteEntry: Codable, Equatable, Sendable {
        var path: String
        var bookmark: Data?
    }
}

/// A file found again, and whether the sandbox lets it be read only with its scope.
nonisolated struct PDFLocatedFile: Equatable, Sendable {
    var url: URL
    var isSecurityScoped: Bool
}

nonisolated final class PDFDocumentRegistry: @unchecked Sendable {
    static let shared = PDFDocumentRegistry()

    static let storageKey = "pdfDocumentRegistry.v1"
    /// Oldest records go first beyond this.
    static let capacity = 400
    static let notesPerDocument = 50

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var records: [String: PDFDocumentRecord]
    /// Whether a bookmark is minted with the sandbox's scope; a unit test, running
    /// outside the sandbox, turns it off.
    private let scoped: Bool

    init(defaults: UserDefaults = AppDefaults.store, scoped: Bool = true) {
        self.defaults = defaults
        self.scoped = scoped
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: PDFDocumentRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    // MARK: Documents

    func record(for id: String) -> PDFDocumentRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[id]
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }

    /// Remembers where the document with identity `id` is. Called when a PDF is
    /// opened and when a passage of it is quoted.
    func register(id: String, url: URL, title: String) {
        guard PDFCitation.isValidID(id), url.isFileURL else { return }
        let bookmark = bookmark(for: url)
        lock.lock(); defer { lock.unlock() }
        var record = records[id] ?? PDFDocumentRecord(id: id, title: title, lastPath: url.path, bookmark: nil, updatedAt: Date())
        if !title.isEmpty { record.title = title }
        record.lastPath = url.standardizedFileURL.path
        if let bookmark { record.bookmark = bookmark }
        record.updatedAt = Date()
        records[id] = record
        pruneAndSave()
    }

    /// Where the bookmark says the document is now, if it still is somewhere:
    /// the file moved or renamed is found here. A stale bookmark is refreshed.
    func locate(id: String, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> PDFLocatedFile? {
        guard let record = record(for: id) else { return nil }
        if let data = record.bookmark {
            var stale = false
            let options: URL.BookmarkResolutionOptions = scoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
            if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                let started = scoped && url.startAccessingSecurityScopedResource()
                defer { if started { url.stopAccessingSecurityScopedResource() } }
                if fileExists(url) {
                    if stale { register(id: id, url: url, title: record.title) }
                    return PDFLocatedFile(url: url, isSecurityScoped: scoped)
                }
            }
        }
        let last = URL(fileURLWithPath: record.lastPath)
        return fileExists(last) ? PDFLocatedFile(url: last, isSecurityScoped: false) : nil
    }

    // MARK: Notes that quote a document

    /// A note that quoted (or links to) the document; the reverse link finds it again.
    func recordNote(_ note: URL, citing id: String) {
        guard PDFCitation.isValidID(id), note.isFileURL else { return }
        let path = note.standardizedFileURL.path
        let bookmark = bookmark(for: note)
        lock.lock(); defer { lock.unlock() }
        guard var record = records[id] else { return }
        record.notes.removeAll { $0.path == path }
        record.notes.insert(.init(path: path, bookmark: bookmark), at: 0)
        if record.notes.count > Self.notesPerDocument { record.notes.removeLast(record.notes.count - Self.notesPerDocument) }
        records[id] = record
        pruneAndSave()
    }

    /// The remembered notes that still exist, with the scope to read each.
    func notes(citing id: String, fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [PDFLocatedFile] {
        guard let record = record(for: id) else { return [] }
        return record.notes.compactMap { entry in
            if let data = entry.bookmark {
                var stale = false
                let options: URL.BookmarkResolutionOptions = scoped ? [.withSecurityScope, .withoutUI] : [.withoutUI]
                if let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                    let started = scoped && url.startAccessingSecurityScopedResource()
                    defer { if started { url.stopAccessingSecurityScopedResource() } }
                    if fileExists(url) { return PDFLocatedFile(url: url, isSecurityScoped: scoped) }
                }
            }
            let url = URL(fileURLWithPath: entry.path)
            return fileExists(url) ? PDFLocatedFile(url: url, isSecurityScoped: false) : nil
        }
    }

    // MARK: Storage

    private func bookmark(for url: URL) -> Data? {
        if scoped, let data = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return data
        }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Caller holds the lock.
    private func pruneAndSave() {
        if records.count > Self.capacity {
            let drop = records.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(records.count - Self.capacity)
            for record in drop { records[record.id] = nil }
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) }
    }
}
