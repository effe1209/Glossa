//
//  TabManager+PDFCitations.swift
//  PageFlow
//
//  The two directions of a PDF ⇄ note link. Quoting: a passage selected in a PDF
//  becomes a quote in the active note, with its page and a link back. Following:
//  a clicked link opens the PDF (the tab already showing it, if any), goes to
//  the page and marks the passage; a PDF that can't be found says so and lets
//  the reader point at it. The format is `PDFCitation`, the identity
//  `PDFDocumentFingerprint`, the places it remembers `PDFDocumentRegistry`.
//

import AppKit
import Foundation
import MarkdownEngine
import PDFKit
import UniformTypeIdentifiers

extension TabManager {

    // MARK: - Quoting a passage in a note

    /// The note a quote goes to: the Markdown tab this window used last.
    var noteReceivingQuotes: (id: UUID, content: MarkdownContent)? {
        for id in tabRecency.order {
            if let content = sessions[id]?.content.markdown, tabs.contains(where: { $0.id == id }) { return (id, content) }
        }
        return nil
    }

    /// "Copy to Note as Markdown": quotes `selection` of `pdf` into the active note.
    /// Without a note, or when the note can't take it now, the quote goes to the
    /// clipboard instead and the reader is told.
    func quoteSelectionInNote(_ selection: PDFSelection, from pdf: PDFManager) {
        guard pdf.permissions.copy, let document = pdf.document, let url = pdf.documentURL,
              let text = selection.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            postTransientToast("Nothing to quote: this PDF doesn’t allow copying text")
            return
        }
        guard let id = pdf.citationID() else {
            postTransientToast("Couldn’t identify this PDF")
            return
        }
        let note = noteReceivingQuotes
        let noteURL = note?.content.documentManager.documentURL
        let index = selection.pages.first.map { document.index(for: $0) }
        let page = (index.flatMap { $0 == NSNotFound ? nil : $0 } ?? pdf.currentPageIndex) + 1

        let pageRange = index.flatMap { $0 == NSNotFound ? nil : document.page(at: $0) }.flatMap { Self.range(of: selection, on: $0) }
        PDFDocumentRegistry.shared.register(id: id, url: url, title: pdf.citationTitle)
        let citation = PDFCitation(
            title: pdf.citationTitle, page: page,
            path: PDFCitation.linkPath(to: url, from: noteURL?.deletingLastPathComponent()),
            documentID: id, quote: text, range: pageRange)
        let block = citation.markdown().trimmingCharacters(in: .newlines)

        guard let note else {
            copyToClipboard(block)
            postTransientToast("Open a note to add quotes — this one is on the clipboard")
            return
        }
        if insert(block, into: note.content, tabID: note.id) {
            if let noteURL { PDFDocumentRegistry.shared.recordNote(noteURL, citing: id) }
            let name = noteURL?.deletingPathExtension().lastPathComponent ?? tabs.first { $0.id == note.id }?.displayTitle ?? "note"
            postTransientToast("Quote added to “\(name)”")
        } else {
            copyToClipboard(block)
            postTransientToast("Couldn’t add it to the note — the quote is on the clipboard")
        }
    }

    /// Where `selection` lies in `page`'s text: from its first character to its last on that page.
    static func range(of selection: PDFSelection, on page: PDFPage) -> NSRange? {
        let count = selection.numberOfTextRanges(on: page)
        guard count > 0 else { return nil }
        var low = Int.max, high = 0
        for index in 0..<count {
            let part = selection.range(at: index, on: page)
            guard part.location != NSNotFound else { continue }
            low = min(low, part.location)
            high = max(high, NSMaxRange(part))
        }
        return high > low && low != Int.max ? NSRange(location: low, length: high - low) : nil
    }

    /// Puts `block` at the caret of the note's editor, or at the end of its text
    /// when the split view's plain source editor is showing.
    private func insert(_ block: String, into content: MarkdownContent, tabID: UUID) -> Bool {
        if markdownSplitView(for: tabID) {
            let text = content.documentManager.text
            let end = NSRange(location: (text as NSString).length, length: 0)
            content.documentManager.text = text + MarkdownEditorController.blockInsertion(of: block, into: text, replacing: end)
            return true
        }
        return content.editorController.insertBlockAtSelection(block, actionName: "Insert Quote")
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Following a citation

    /// Whether `link` (clicked in a note) is a citation: a PDF link that carries a document identity.
    static func isPDFCitation(_ link: URL) -> Bool {
        link.pathExtension.lowercased() == "pdf" && PDFCitation.Reference(link: link) != nil
    }

    /// Opens the cited PDF at its page and marks the passage.
    @discardableResult
    func openPDFCitation(_ link: URL, from content: MarkdownContent) -> Task<Void, Never>? {
        guard let reference = PDFCitation.Reference(link: link) else {
            postTransientToast("This PDF reference isn’t valid")
            return nil
        }
        if showOpenCitedDocument(reference) { return nil }
        let noteFolder = content.documentManager.documentURL?.deletingLastPathComponent()
        return Task { [weak self] in
            let outcome = await Self.resolveCitation(reference, noteFolder: noteFolder)
            guard let self else { return }
            switch outcome {
            case .found(let file): self.openCitedPDF(file, reference)
            case .missing(let name): self.offerToLocate(name, for: reference)
            }
        }
    }

    /// The tab already showing the cited document, in this or any window: brought forward at the page.
    private func showOpenCitedDocument(_ reference: PDFCitation.Reference) -> Bool {
        let managers = [self] + WindowRegistry.shared.allOpenTabs().map(\.tabManager).filter { $0 !== self }
        for manager in managers {
            for tab in manager.tabs {
                guard let pdf = manager.sessions[tab.id]?.pdfManager, pdf.citationID() == reference.documentID,
                      let url = pdf.documentURL else { continue }
                manager.selectTab(tab.id)
                WindowRegistry.shared.bringToFront(for: manager)
                pdf.followPageLink(reference.page - 1, for: url)
                if let snippet = reference.snippet { pdf.highlightPassage(snippet, range: reference.range, onPageIndex: reference.page - 1) }
                return true
            }
        }
        return false
    }

    private func openCitedPDF(_ file: PDFLocatedFile, _ reference: PDFCitation.Reference) {
        let folderAccess = FolderAccessStore.shared
        // A file reachable only through a folder the user allowed opens scoped.
        let scoped = file.isSecurityScoped || FileManager.default.isReadableFile(atPath: file.url.path)
            ? nil : folderAccess.scopedURL(for: file.url)
        openDocument(url: scoped ?? file.url, isSecurityScoped: file.isSecurityScoped || scoped != nil,
                     pdfPageIndex: reference.page - 1)
        guard let snippet = reference.snippet, let tab = tabID(for: file.url),
              let pdf = sessions[tab]?.pdfManager else { return }
        pdf.highlightPassage(snippet, range: reference.range, onPageIndex: reference.page - 1)
    }

    /// Resolves off the main thread, with the note's folder opened for reading.
    nonisolated private static func resolveCitation(_ reference: PDFCitation.Reference, noteFolder: URL?) async -> PDFCitationResolver.Outcome {
        await Task.detached(priority: .userInitiated) {
            let resolver = PDFCitationResolver()
            guard let noteFolder else { return resolver.resolve(reference, noteFolder: nil) }
            return FolderAccessStore.shared.withAccess(to: noteFolder) { resolver.resolve(reference, noteFolder: noteFolder) }
        }.value
    }

    // MARK: - A PDF that can't be found

    /// Says the document is missing and offers to locate it; the file the reader
    /// picks is checked to be the same document before it is trusted.
    private func offerToLocate(_ name: String, for reference: PDFCitation.Reference) {
        guard !TestEnvironment.isRunningTests else {
            postTransientToast("Couldn’t find “\(name)”")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Couldn’t find “\(name)”"
        alert.informativeText = "The PDF cited by this note may have been moved, renamed or deleted. Locate it and Glossa will remember where it is."
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose “\(name)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let matches = PDFDocumentFingerprint.of(fileAt: url) == reference.documentID
        if matches {
            PDFDocumentRegistry.shared.register(id: reference.documentID, url: url,
                                                title: PDFDocument(url: url).flatMap { Self.title(of: $0, url: url) } ?? name)
        } else {
            let confirm = NSAlert()
            confirm.messageText = "This doesn’t look like the same PDF"
            confirm.informativeText = "“\(url.lastPathComponent)” differs from the document the note cites, so the page may not match. Open it anyway?"
            confirm.addButton(withTitle: "Open Anyway")
            confirm.addButton(withTitle: "Cancel")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
        }
        openCitedPDF(PDFLocatedFile(url: url, isSecurityScoped: true), reference)
    }

    private static func title(of document: PDFDocument, url: URL) -> String {
        let own = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return own.flatMap { $0.isEmpty ? nil : $0 } ?? url.deletingPathExtension().lastPathComponent
    }

    // MARK: - The notes that cite a PDF

    func commentsSection(for tabID: UUID) -> CommentsSection { sessions[tabID]?.uiState.commentsSection ?? .comments }
    func setCommentsSection(_ value: CommentsSection, for tabID: UUID) { sessions[tabID]?.uiState.commentsSection = value }
    func citingNotes(for tabID: UUID) -> [PDFCitingNote] { sessions[tabID]?.uiState.citingNotes ?? [] }

    /// Looks the notes up again for the tab's PDF and keeps them on the tab.
    func refreshCitingNotes(for tabID: UUID, pdf: PDFManager) async {
        guard pdf.hasDocument else { return }
        let found = await notesCiting(pdf)
        if sessions[tabID]?.uiState.citingNotes != found { sessions[tabID]?.uiState.citingNotes = found }
    }

    /// The active PDF's comments panel, on its Notes section.
    func showNotesThatQuoteActivePDF() {
        guard let id = activeTabID, sessions[id]?.pdfManager != nil else { return }
        setCommentsSection(.notes, for: id)
        setShowingComments(true, for: id)
    }

    /// The notes citing the PDF in `pdf`: the open ones in every window, the ones that remembered
    /// quoting it, and the notes beside the file.
    func notesCiting(_ pdf: PDFManager) async -> [PDFCitingNote] {
        guard let id = pdf.citationID() else { return [] }
        let folder = pdf.documentURL?.deletingLastPathComponent()
        let managers = [self] + WindowRegistry.shared.allOpenTabs().map(\.tabManager).filter { $0 !== self }
        var open: [PDFCitingNotes.OpenNote] = []
        for manager in managers {
            for tab in manager.tabs {
                guard let note = manager.sessions[tab.id]?.content.markdown else { continue }
                open.append(.init(url: note.documentManager.documentURL, text: note.documentManager.text))
            }
        }
        return await Task.detached(priority: .utility) {
            guard let folder else { return PDFCitingNotes.find(id: id, pdfFolder: nil, openNotes: open) }
            return FolderAccessStore.shared.withAccess(to: folder) {
                PDFCitingNotes.find(id: id, pdfFolder: folder, openNotes: open)
            }
        }.value
    }

    /// Opens a note listed as citing a PDF.
    func openCitingNote(_ note: PDFCitingNote) {
        openDocument(url: note.url, isSecurityScoped: note.isSecurityScoped)
    }
}
