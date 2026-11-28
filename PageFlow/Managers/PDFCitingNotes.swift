//
//  PDFCitingNotes.swift
//  PageFlow
//
//  The reverse of a citation: the notes that quote a given PDF. There is no
//  index. A note is looked at where it can be found cheaply: the notes open in
//  a tab (their live text), the notes that remembered quoting the document
//  (`PDFDocumentRegistry`), and the Markdown files beside the PDF. Each is read
//  and its citation links are matched by document identity.
//

import Foundation

nonisolated struct PDFCitingNote: Identifiable, Equatable, Sendable {
    var url: URL
    var isSecurityScoped: Bool
    /// Cited pages, 1-based, ascending, without repeats.
    var pages: [Int]
    /// Citations of the document in the note.
    var count: Int

    var id: String { url.path }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

nonisolated enum PDFCitingNotes {
    static let maxFilesInFolder = 300
    static let maxFileBytes = 2 * 1024 * 1024

    /// The pages of document `id` that `markdown` cites.
    static func citedPages(in markdown: String, of id: String) -> [Int] {
        PDFCitation.references(in: markdown).filter { $0.reference.documentID == id }.map(\.reference.page)
    }

    /// A note open in a tab: where it lives (nil when unsaved) and the text it holds now.
    struct OpenNote: Sendable {
        var url: URL?
        var text: String
    }

    /// Every note that cites document `id`, most citations first. `readFile`
    /// returns a file's text, or nil when it can't be read.
    static func find(
        id: String,
        pdfFolder: URL?,
        openNotes: [OpenNote],
        registry: PDFDocumentRegistry = .shared,
        readFile: (PDFLocatedFile) -> String? = readTextFile
    ) -> [PDFCitingNote] {
        var seen = Set<String>(), found: [PDFCitingNote] = []
        func consider(_ url: URL, scoped: Bool, text: String?) {
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard seen.insert(key).inserted, let text else { return }
            let pages = citedPages(in: text, of: id)
            guard !pages.isEmpty else { return }
            found.append(PDFCitingNote(url: url, isSecurityScoped: scoped, pages: Array(Set(pages)).sorted(), count: pages.count))
        }
        for note in openNotes { if let url = note.url { consider(url, scoped: false, text: note.text) } }
        for file in registry.notes(citing: id) { consider(file.url, scoped: file.isSecurityScoped, text: readFile(file)) }
        if let pdfFolder, let names = try? FileManager.default.contentsOfDirectory(atPath: pdfFolder.path) {
            let notes = names.filter { name in URL.glossaMarkdownExtensions.contains((name as NSString).pathExtension.lowercased()) }
            for name in notes.sorted().prefix(maxFilesInFolder) {
                let url = pdfFolder.appendingPathComponent(name)
                consider(url, scoped: false, text: readFile(PDFLocatedFile(url: url, isSecurityScoped: false)))
            }
        }
        return found.sorted { ($0.count, $1.title) > ($1.count, $0.title) }
    }

    static func readTextFile(_ file: PDFLocatedFile) -> String? {
        let started = file.isSecurityScoped && file.url.startAccessingSecurityScopedResource()
        defer { if started { file.url.stopAccessingSecurityScopedResource() } }
        guard let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxFileBytes else { return nil }
        return try? String(contentsOf: file.url, encoding: .utf8)
    }
}
