//
//  DocumentExporter.swift
//  PageFlow
//
//  Exports a document's Markdown as HTML, a Word document (.docx) or a PDF.
//  HTML is written as is; the other two lay the HTML out with AppKit.
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

    /// Asks where to save, then writes `markdown` in `format`.
    static func export(markdown: String, title: String, format: Format, baseURL: URL? = nil,
                       from window: NSWindow? = nil, onFailure: @escaping (String) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(title).\(format.fileExtension)"
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(markdown: markdown, title: title, format: format, baseURL: baseURL, to: url)
            } catch {
                onFailure("Export failed: \(error.localizedDescription)")
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }

    static func write(markdown: String, title: String, format: Format, baseURL: URL? = nil, to url: URL) throws {
        let html = MarkdownHTML.page(from: markdown, title: title)
        switch format {
        case .html:
            try html.write(to: url, atomically: true, encoding: .utf8)
        case .docx:
            let text = try attributedString(fromHTML: html, baseURL: baseURL)
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url, options: .atomic)
        case .pdf:
            try writePDF(attributed: try attributedString(fromHTML: html, baseURL: baseURL), to: url)
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

    /// Paginated A4, laid out in a text view and printed to a file.
    private static func writePDF(attributed: NSAttributedString, to url: URL) throws {
        let page = NSSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let printInfo = NSPrintInfo()
        printInfo.paperSize = page
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: page.width - 2 * margin - 8, height: page.height - 2 * margin))
        textView.appearance = NSAppearance(named: .aqua)
        textView.isEditable = false
        textView.drawsBackground = true
        textView.backgroundColor = .white
        textView.textContainerInset = .zero
        textView.textStorage?.setAttributedString(attributed)
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            // Exactly the text's height, so no empty page trails it.
            textView.setFrameSize(NSSize(width: textView.frame.width, height: ceil(layout.usedRect(for: container).height)))
        }

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: url.path) else {
            throw ExportError(errorDescription: "The PDF could not be written.")
        }
    }
}
