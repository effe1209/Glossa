//
//  MarkdownContent+Export.swift
//  PageFlow
//
//  Exporting the note as PDF, HTML or a Word document: one path for File ▸ Export As
//  and the Markdown toolbar's Export button.
//

import AppKit

extension MarkdownContent {
    /// There is text to export.
    var canExport: Bool { !documentManager.text.isEmpty }

    /// Asks where to save, then writes the note in `format`. A failure is shown to the reader.
    func exportDocument(as format: DocumentExporter.Format, from window: NSWindow? = nil) {
        reconcileLiveText()
        let manager = documentManager
        DocumentExporter.export(markdown: manager.text, title: manager.documentTitle, format: format,
                                baseURL: manager.documentURL?.deletingLastPathComponent(),
                                from: window ?? NSApp.keyWindow) { message in
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
