//
//  DocumentExporter.swift
//  PageFlow
//
//  Exports a document's Markdown as HTML, a Word document (.docx) or a PDF.
//  HTML is written as is; a PDF is laid out and printed by WebKit, a Word document by AppKit.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum DocumentExporter {
    enum Format: CaseIterable {
        case pdf, html, docx

        var fileExtension: String {
            switch self { case .pdf: "pdf"; case .html: "html"; case .docx: "docx" }
        }
        var menuTitle: String {
            switch self { case .pdf: "PDF…"; case .html: "HTML…"; case .docx: "Word Document…" }
        }
        var contentType: UTType {
            switch self {
            case .pdf: .pdf
            case .html: .html
            case .docx: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
            }
        }
    }

    struct ExportError: LocalizedError {
        let errorDescription: String?
    }

    /// Asks where to save, then writes `markdown` in `format`. A PDF also asks how large to set the text.
    static func export(markdown: String, title: String, format: Format, baseURL: URL? = nil,
                       from window: NSWindow? = nil, onFailure: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(title).\(format.fileExtension)"
        panel.canCreateDirectories = true
        let scalePicker = format == .pdf ? ScalePicker() : nil
        panel.accessoryView = scalePicker?.view
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let scale = scalePicker?.scale ?? 1
            if scalePicker != nil { PDFExport.preferredScale = scale }
            Task { @MainActor in
                do {
                    try await write(markdown: markdown, title: title, format: format, baseURL: baseURL, scale: scale, to: url)
                } catch {
                    onFailure("Export failed: \(error.localizedDescription)")
                }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    /// Writes `markdown` in `format`. `scale` sets the size of a PDF's text (1 is 100%).
    static func write(markdown: String, title: String, format: Format, baseURL: URL? = nil, scale: Double = 1,
                      to url: URL) async throws {
        switch format {
        case .html:
            // Formulas are typeset and embedded as images, so the page needs nothing else to show them.
            let html = MarkdownHTML.page(from: markdown, title: title, math: MathExport.embedded, code: CodeExport.html)
            try html.write(to: url, atomically: true, encoding: .utf8)
        case .docx:
            // AppKit's Word writer keeps text and drops pictures, so formulas stay as their source here.
            let html = MarkdownHTML.page(from: markdown, title: title, code: CodeExport.html)
            let text = try attributedString(fromHTML: html, baseURL: baseURL)
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url, options: .atomic)
        case .pdf:
            let html = MarkdownHTML.page(from: markdown, title: title, math: MathExport.embedded, code: CodeExport.html, scale: scale)
            try await PDFExport.write(html: html, baseURL: baseURL, to: url)
        }
    }

    /// The Save panel's "Scale" row for a PDF.
    @MainActor
    private final class ScalePicker {
        private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 44))

        init() {
            for scale in PDFExport.scales { popup.addItem(withTitle: PDFExport.title(for: scale)) }
            popup.selectItem(at: PDFExport.scales.firstIndex(of: PDFExport.preferredScale) ?? 0)
            let label = NSTextField(labelWithString: "Scale:")
            label.frame = NSRect(x: 8, y: 12, width: 48, height: 20)
            popup.frame = NSRect(x: 60, y: 8, width: 120, height: 26)
            view.addSubview(label)
            view.addSubview(popup)
        }

        var scale: Double {
            let index = popup.indexOfSelectedItem
            return PDFExport.scales.indices.contains(index) ? PDFExport.scales[index] : 1
        }
    }

    private static func attributedString(fromHTML html: String, baseURL: URL?) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        if let baseURL { options[.baseURL] = baseURL }
        guard let data = html.data(using: .utf8) else { throw ExportError(errorDescription: "The text could not be encoded.") }
        return try NSAttributedString(data: data, options: options, documentAttributes: nil)
    }
}
