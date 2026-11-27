//
//  MarkdownSplitView.swift
//  PageFlow
//
//  A Markdown tab's split view: the raw source on the left, an uneditable
//  preview on the right, drawn as a white page like a PDF. Double-clicking
//  the preview moves the source to the line it came from.
//

import SwiftUI
import AppKit
import WebKit

/// A request to reveal a source line; a new `token` asks again for the same line.
struct SourceLineReveal: Equatable {
    var line: Int
    var token: Int
}

struct MarkdownSplitView: View {
    @Bindable var content: MarkdownContent
    let fontSize: CGFloat
    let topInset: CGFloat
    let appearanceName: NSAppearance.Name?

    @State private var reveal = SourceLineReveal(line: 0, token: 0)

    var body: some View {
        HStack(spacing: 0) {
            MarkdownSourceEditor(
                text: Binding(
                    get: { content.documentManager.text },
                    set: { content.documentManager.text = $0 }
                ),
                fontSize: fontSize,
                topInset: topInset,
                appearanceName: appearanceName,
                undoManager: content.undoManager,
                reveal: reveal
            )
            Divider()
            MarkdownPreviewView(
                markdown: content.documentManager.text,
                baseURL: content.documentManager.documentURL?.deletingLastPathComponent(),
                topInset: topInset,
                onDoubleClick: { line in reveal = SourceLineReveal(line: line, token: reveal.token + 1) }
            )
        }
    }
}

// MARK: - Source

private struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let topInset: CGFloat
    let appearanceName: NSAppearance.Name?
    let undoManager: UndoManager?
    let reveal: SourceLineReveal

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 18, height: 12)
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.string = text
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.hasVerticalScroller = true
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        scrollView.appearance = appearanceName.flatMap { NSAppearance(named: $0) }
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: 0, right: 0)
        let font = NSFont.monospacedSystemFont(ofSize: max(11, fontSize - 1), weight: .regular)
        if textView.font != font { textView.font = font }
        // An outside change (undo through the tab, a reload) reaches the view;
        // the view's own edits already match, so this is a no-op for them.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
        }
        if reveal.token != context.coordinator.lastRevealToken {
            context.coordinator.lastRevealToken = reveal.token
            context.coordinator.reveal(line: reveal.line, in: scrollView)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownSourceEditor
        weak var textView: NSTextView?
        var lastRevealToken = 0
        private var highlighted: NSRange?
        private var fadeWork: [DispatchWorkItem] = []

        /// The revealed line stays marked for a few seconds, fading out.
        private func mark(_ range: NSRange, in layout: NSLayoutManager) {
            clearMark(in: layout)
            guard range.length > 0 else { return }
            highlighted = range
            func paint(_ alpha: CGFloat) {
                guard let highlighted, NSMaxRange(highlighted) <= (layout.textStorage?.length ?? 0) else { return }
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(alpha),
                                             forCharacterRange: highlighted)
            }
            paint(0.45)
            let steps: [(Double, CGFloat)] = [(2.4, 0.3), (3.2, 0.15)]
            for (delay, alpha) in steps {
                let work = DispatchWorkItem { paint(alpha) }
                fadeWork.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
            let end = DispatchWorkItem { [weak self, weak layout] in
                guard let self, let layout else { return }
                self.clearMark(in: layout)
            }
            fadeWork.append(end)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: end)
        }

        private func clearMark(in layout: NSLayoutManager) {
            fadeWork.forEach { $0.cancel() }
            fadeWork = []
            if let highlighted, NSMaxRange(highlighted) <= (layout.textStorage?.length ?? 0) {
                layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: highlighted)
            }
            highlighted = nil
        }

        init(_ parent: MarkdownSourceEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
        }

        func undoManager(for view: NSTextView) -> UndoManager? { parent.undoManager }

        /// Centres the line in the view and flashes it.
        func reveal(line: Int, in scrollView: NSScrollView) {
            guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
            let string = textView.string as NSString
            var location = 0
            for _ in 0..<max(0, line) {
                guard location < string.length else { break }
                location = NSMaxRange(string.lineRange(for: NSRange(location: location, length: 0)))
            }
            location = min(location, max(0, string.length - 1))
            let range = string.length == 0 ? NSRange(location: 0, length: 0) : string.lineRange(for: NSRange(location: location, length: 0))
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            let visible = scrollView.contentView.bounds.height
            let y = max(0, rect.midY + textView.textContainerInset.height - visible / 2)
            scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y - scrollView.contentInsets.top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            mark(range, in: layout)
        }
    }
}

// MARK: - Preview

private struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    let topInset: CGFloat
    let onDoubleClick: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "line")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = NSColor(white: 0.9, alpha: 1)
        context.coordinator.webView = webView
        webView.loadHTMLString(Self.shell(body: MarkdownHTML.body(from: markdown, annotated: true), topInset: topInset),
                               baseURL: baseURL)
        context.coordinator.rendered = markdown
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard coordinator.rendered != markdown || coordinator.renderedInset != topInset else { return }
        // Typing renders a moment after the last key, in place so the page
        // keeps its scroll position.
        coordinator.pending?.cancel()
        let markdown = markdown, inset = topInset
        let work = DispatchWorkItem { [weak coordinator] in
            guard let coordinator else { return }
            coordinator.rendered = markdown
            coordinator.renderedInset = inset
            let body = MarkdownHTML.body(from: markdown, annotated: true)
            let payload = (try? JSONSerialization.data(withJSONObject: [body], options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
            coordinator.webView?.evaluateJavaScript("setBody(\(payload)[0], \(Int(inset)))", completionHandler: nil)
        }
        coordinator.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "line")
        coordinator.pending?.cancel()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: MarkdownPreviewView
        weak var webView: WKWebView?
        var rendered = ""
        var renderedInset: CGFloat = 0
        var pending: DispatchWorkItem?

        init(_ parent: MarkdownPreviewView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let line = message.body as? Int else { return }
            parent.onDoubleClick(line)
        }
    }

    /// The page: grey desk, one white sheet like a PDF page. Always light,
    /// whatever the app's appearance.
    private static func shell(body: String, topInset: CGFloat) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        html { background: #e6e6e9; }
        body { margin: 0; padding: \(Int(topInset))px 24px 40px; font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 15px; line-height: 1.6; color: #1d1d1f; }
        #c { background: #fff; max-width: 780px; min-height: 90vh; margin: 0 auto; padding: 48px 56px; box-shadow: 0 1px 4px rgba(0,0,0,.18), 0 4px 18px rgba(0,0,0,.10); box-sizing: border-box; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.3em 0 0.5em; }
        h1 { font-size: 2em; margin-top: 0; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        code { font-family: Menlo, Consolas, monospace; font-size: .9em; background: #f2f2f4; padding: .1em .3em; border-radius: 3px; }
        pre { background: #f2f2f4; padding: .8em 1em; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 1em 0; padding: 0 1em; border-left: 3px solid #c7c7cc; color: #555; }
        table { border-collapse: collapse; margin: 1em 0; }
        th, td { border: 1px solid #d1d1d6; padding: .4em .8em; text-align: left; }
        th { background: #f2f2f4; }
        img { max-width: 100%; } hr { border: none; border-top: 1px solid #d1d1d6; margin: 2em 0; }
        a { color: #0a60d8; } [data-line] { cursor: default; }
        </style></head>
        <body><div id="c">\(body)</div>
        <script>
        function setBody(html, top) { document.getElementById('c').innerHTML = html; document.body.style.paddingTop = top + 'px'; }
        document.addEventListener('dblclick', function (e) {
          var el = e.target.closest('[data-line]');
          if (el) { window.getSelection().removeAllRanges(); window.webkit.messageHandlers.line.postMessage(parseInt(el.getAttribute('data-line'), 10)); }
        });
        </script></body></html>
        """
    }
}
