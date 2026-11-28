//
//  PDFExport.swift
//  PageFlow
//
//  Writes a note's HTML as a paginated PDF through WebKit, so the page looks as its
//  stylesheet says (typography, callouts, code, tables) rather than as AppKit's
//  simpler text layout would draw it.
//

import AppKit
import WebKit

@MainActor
enum PDFExport {
    /// The sizes the export offers: how large the text is set on the page.
    static let scales: [Double] = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5]
    static let defaultScale = 1.0
    private static let scaleKey = "glossa.export.pdfScale"

    /// The reader's last choice, if it is one the export offers.
    static var preferredScale: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: scaleKey)
            return scales.contains(saved) ? saved : defaultScale
        }
        set { UserDefaults.standard.set(newValue, forKey: scaleKey) }
    }

    static func title(for scale: Double) -> String { "\(Int((scale * 100).rounded()))%" }

    /// Lays `html` out on A4 pages and writes them to `url`.
    static func write(html: String, baseURL: URL?, to url: URL) async throws {
        let paper = NSSize(width: 595.28, height: 841.89)      // A4 in points
        let session = Session(paper: paper)
        try await session.load(html: html, baseURL: baseURL)
        try await session.print(to: url)
    }

    /// One render: an offscreen web view, loaded and then printed to a file.
    @MainActor
    private final class Session: NSObject, WKNavigationDelegate {
        private let paper: NSSize
        private let window: NSWindow
        private let webView: WKWebView
        private var loaded: CheckedContinuation<Void, Error>?
        private var printed: CheckedContinuation<Bool, Never>?

        init(paper: NSSize) {
            self.paper = paper
            // Laid out at the paper's width less its margins, as the print will be.
            webView = WKWebView(frame: NSRect(origin: .zero, size: paper), configuration: WKWebViewConfiguration())
            window = NSWindow(contentRect: NSRect(origin: .zero, size: paper), styleMask: [.borderless], backing: .buffered, defer: true)
            super.init()
            window.contentView = webView
            window.isReleasedWhenClosed = false
            webView.navigationDelegate = self
        }

        func load(html: String, baseURL: URL?) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                loaded = continuation
                webView.loadHTMLString(html, baseURL: baseURL)
            }
        }

        func print(to url: URL) async throws {
            let info = NSPrintInfo()
            info.paperSize = paper
            info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

            let operation = webView.printOperation(with: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.view?.frame = NSRect(origin: .zero, size: paper)
            let ok = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                printed = continuation
                operation.runModal(for: window, delegate: self, didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
            }
            guard ok, FileManager.default.fileExists(atPath: url.path) else {
                throw DocumentExporter.ExportError(errorDescription: "The PDF could not be written.")
            }
        }

        @objc private func printDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            printed?.resume(returning: success)
            printed = nil
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // A beat for images and fonts to settle before the pages are cut.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.loaded?.resume()
                self?.loaded = nil
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loaded?.resume(throwing: error); loaded = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loaded?.resume(throwing: error); loaded = nil
        }
    }
}
