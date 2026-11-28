//
//  PDFDocumentRegistry.swift
//  Glossa
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
import os.log

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

    /// Where the registry lives now, and where it lived before it was named for Glossa.
    /// - The new key, when it holds a registry, is the registry.
    /// - When the new key is missing, the old one is read (and never written or removed).
    /// - When the new key is there but unreadable, the old one is **not** used in its place:
    ///   both are kept as they are, `issue` says so, and nothing is written over the unreadable
    ///   value until `recoverFromLegacy()` is asked for explicitly.
    static let storageKey = "glossa.pdfDocumentRegistry.v1"
    static let legacyStorageKey = "pdfDocumentRegistry.v1"
    /// Where an unreadable registry is set aside by `recoverFromLegacy()`, with the time appended.
    static let unreadableKeyPrefix = storageKey + ".unreadable."
    private static let logger = Logger(subsystem: "com.pageflow", category: "PDFDocumentRegistry")

    enum Issue: Equatable, Sendable {
        /// `glossa.pdfDocumentRegistry.v1` exists and is not a registry. The registry is empty for
        /// this launch and is not saved, so the unreadable value stays where it is.
        case unreadable
    }

    /// Set when the saved registry could not be used; read-only for everyone but `recoverFromLegacy()`.
    private(set) var issue: Issue?
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
        if let current = defaults.object(forKey: Self.storageKey) {
            if let data = current as? Data, let decoded = Self.decode(data) {
                records = decoded
            } else {
                // Present but not a registry: no quiet fallback to the older one, no overwriting.
                records = [:]
                issue = .unreadable
                Self.logger.error("The saved PDF registry (\(Self.storageKey, privacy: .public)) is unreadable; it and \(Self.legacyStorageKey, privacy: .public) are left as they are and nothing is saved until it is recovered.")
            }
        } else {
            records = defaults.data(forKey: Self.legacyStorageKey).flatMap(Self.decode) ?? [:]
        }
    }

    private static func decode(_ data: Data) -> [String: PDFDocumentRecord]? {
        try? JSONDecoder().decode([String: PDFDocumentRecord].self, from: data)
    }

    /// The explicit way out of `.unreadable`, which nothing calls on its own: the unreadable value
    /// is set aside under `unreadableKeyPrefix` + the time (kept, never deleted), the registry
    /// becomes the older one, and it is saved under the Glossa key. The older key is not touched.
    /// False, and nothing changed, when there is no issue, the older registry is not readable, or
    /// the recovered registry cannot be encoded and read back: the new registry is built and checked
    /// first, and only then is anything written; if a write fails the unreadable value is put back
    /// under the Glossa key, the set-aside copy stays, and the registry stays `.unreadable`.
    @discardableResult
    func recoverFromLegacy(now: Date = Date(),
                           encode: ([String: PDFDocumentRecord]) throws -> Data = { try JSONEncoder().encode($0) }) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard issue == .unreadable,
              var older = defaults.data(forKey: Self.legacyStorageKey).flatMap(Self.decode),
              let unreadable = defaults.object(forKey: Self.storageKey) else { return false }
        if older.count > Self.capacity {
            for record in older.values.sorted(by: { $0.updatedAt < $1.updatedAt }).prefix(older.count - Self.capacity) { older[record.id] = nil }
        }
        guard let data = try? encode(older), Self.decode(data) == older else { return false }

        var setAside = Self.unreadableKeyPrefix + String(Int(now.timeIntervalSince1970))
        while defaults.object(forKey: setAside) != nil { setAside += "x" }
        defaults.set(unreadable, forKey: setAside)
        guard defaults.object(forKey: setAside) != nil else { return false }
        defaults.set(data, forKey: Self.storageKey)
        guard let saved = defaults.data(forKey: Self.storageKey), Self.decode(saved) == older else {
            defaults.set(unreadable, forKey: Self.storageKey)   // put the original back; the copy stays
            return false
        }
        records = older
        issue = nil
        return true
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

    /// Caller holds the lock. With an unreadable saved registry it changes memory only.
    private func pruneAndSave() {
        if records.count > Self.capacity {
            let drop = records.values.sorted { $0.updatedAt < $1.updatedAt }.prefix(records.count - Self.capacity)
            for record in drop { records[record.id] = nil }
        }
        guard issue == nil else { return }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) }
    }
}
