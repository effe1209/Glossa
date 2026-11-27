//
//  PDFDocumentFingerprint.swift
//  PageFlow
//
//  The stable identity of a PDF, for citations that must find it again after
//  it is moved or renamed. It is not the path, and not a hash of the bytes:
//  Glossa saves highlights and comments into the file, which rewrites it. It
//  is a hash of what the reader sees stay the same: the page count, the
//  first page's size and the text of the first pages. A scan with no text
//  falls back to the head of the file.
//

import Foundation
import CryptoKit
import PDFKit

nonisolated enum PDFDocumentFingerprint {
    /// Pages looked at for text, and pages whose text is used.
    static let pagesScanned = 12
    static let pagesUsed = 3
    static let charactersPerPage = 1_500
    static let headBytes = 64 * 1024

    /// 16 lowercase hex digits (64 bits of SHA-256): enough to tell the
    /// documents of one person's library apart, short enough to read in a link.
    static func make(pageCount: Int, firstPageSize: CGSize, pageTexts: [String], head: () -> Data?) -> String {
        var material = "v1|\(pageCount)|\(Int(firstPageSize.width.rounded()))x\(Int(firstPageSize.height.rounded()))"
        let texts = pageTexts.map(normalized).filter { !$0.isEmpty }.prefix(pagesUsed)
        if texts.isEmpty {
            material += "|head|"
            return hex(of: Data(material.utf8) + (head() ?? Data()))
        }
        for text in texts { material += "|" + text }
        return hex(of: Data(material.utf8))
    }

    /// Lowercased and with every run of spaces folded, so extraction
    /// differences in spacing or case do not change the identity.
    static func normalized(_ text: String) -> String {
        let folded = text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return String(folded.prefix(charactersPerPage))
    }

    private static func hex(of data: Data) -> String {
        SHA256.hash(data: data).prefix(PDFCitation.idLength / 2).map { String(format: "%02x", $0) }.joined()
    }

    /// The identity of a loaded document. `fileURL` supplies the head of the
    /// file for a document with no text. Nil for a locked or empty document.
    static func of(_ document: PDFDocument, fileURL: URL? = nil) -> String? {
        guard !document.isLocked, document.pageCount > 0, let first = document.page(at: 0) else { return nil }
        var texts: [String] = []
        var used = 0
        for index in 0..<min(document.pageCount, pagesScanned) {
            let text = document.page(at: index)?.string ?? ""
            texts.append(text)
            if !normalized(text).isEmpty { used += 1 }
            if used >= pagesUsed { break }
        }
        return make(pageCount: document.pageCount, firstPageSize: first.bounds(for: .mediaBox).size, pageTexts: texts) {
            guard let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
            defer { try? handle.close() }
            return try? handle.read(upToCount: headBytes)
        }
    }

    /// The identity of the file at `url`, read off the calling thread; nil
    /// when it can't be opened as an unlocked PDF.
    static func of(fileAt url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        return of(document, fileURL: url)
    }
}
