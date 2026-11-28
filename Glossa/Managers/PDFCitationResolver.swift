//
//  PDFCitationResolver.swift
//  Glossa
//
//  Finds the PDF a citation points at, in this order:
//    1. the file at the link's path, when it is the same document;
//    2. where the registry's bookmark says the document is now (moved, renamed);
//    3. a file of the same name in the note's folders and the ones the user
//       allowed, when it is the same document.
//  "The same document" is the identity the link carries, never just the name:
//  two PDFs called `paper.pdf` are told apart, and a different file at the old
//  path is not mistaken for it. Nothing found is an answer, not a guess.
//
//  Run it off the main thread: it reads files.
//

import Foundation

nonisolated struct PDFCitationResolver: Sendable {
    enum Outcome: Equatable, Sendable {
        case found(PDFLocatedFile)
        /// Not found; the name the link or the registry remembers, to say what to look for.
        case missing(name: String)
    }

    var registry: PDFDocumentRegistry = .shared
    /// The identity of the PDF at a URL; nil when it can't be read as one.
    var identity: @Sendable (URL) -> String? = { PDFDocumentFingerprint.of(fileAt: $0) }
    var fileExists: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    /// Folders searched by name (besides the note's own), each opened for reading by the caller.
    var searchFolders: [URL] = []
    /// A folder is searched this many levels down, and no more than `maxEntries` files in all.
    var maxDepth = 3
    var maxEntries = 5_000

    func resolve(_ reference: PDFCitation.Reference, noteFolder: URL?) -> Outcome {
        let linked = Self.linkedURL(reference.path, noteFolder: noteFolder)
        let record = registry.record(for: reference.documentID)
        let written = (reference.path as NSString).lastPathComponent
        let name = !written.isEmpty ? written : record.map { URL(fileURLWithPath: $0.lastPath).lastPathComponent } ?? "PDF"

        // 1. The path the note wrote.
        if let linked, fileExists(linked), identity(linked) == reference.documentID {
            return .found(PDFLocatedFile(url: linked, isSecurityScoped: false))
        }
        // 2. Where the document went.
        if let located = registry.locate(id: reference.documentID, fileExists: fileExists), identity(located.url) == reference.documentID {
            return .found(located)
        }
        // 3. The same name in nearby folders.
        let folders = ([linked?.deletingLastPathComponent(), noteFolder].compactMap { $0 } + searchFolders)
        for candidate in candidates(named: name, in: folders) where identity(candidate) == reference.documentID {
            return .found(PDFLocatedFile(url: candidate, isSecurityScoped: false))
        }
        return .missing(name: name)
    }

    /// The URL a link's path means from the note's folder; nil for a path that can't be resolved.
    static func linkedURL(_ path: String, noteFolder: URL?) -> URL? {
        if path.hasPrefix("file:") { return URL(string: path).map { $0.standardizedFileURL } }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        guard let noteFolder else { return nil }
        // Appended, not `relativeTo:`: a folder URL without a trailing slash would resolve beside it.
        return URL(fileURLWithPath: noteFolder.path).appendingPathComponent(path).standardizedFileURL
    }

    /// Files called `name` under `folders` (compared without case), nearest first.
    func candidates(named name: String, in folders: [URL]) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        var budget = maxEntries
        for folder in folders {
            let root = folder.standardizedFileURL
            guard seen.insert(root.path).inserted,
                  let walker = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                budget -= 1
                if budget < 0 { return out }
                if walker.level > maxDepth { walker.skipDescendants(); continue }
                if url.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame, !out.contains(url) { out.append(url) }
            }
        }
        return out
    }
}
