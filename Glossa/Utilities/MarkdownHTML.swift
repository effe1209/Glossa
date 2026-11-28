//
//  MarkdownHTML.swift
//  Glossa
//
//  A small Markdown-to-HTML converter for exporting: headings, paragraphs,
//  emphasis, code, links, images, quotes, lists (nested, with task items),
//  tables and rules. Pure text in, text out.
//

import Foundation

enum MarkdownHTML {
    /// Writes a formula as HTML: `(latex, isDisplay) -> html`. Set only while a document is
    /// converted with `math:`; without it formulas stay as their source text.
    typealias MathRenderer = (_ latex: String, _ isDisplay: Bool) -> String
    private nonisolated(unsafe) static var mathRenderer: MathRenderer?

    /// Writes a code block's contents as HTML (coloured spans, already escaped), or nil to leave it plain.
    typealias CodeRenderer = (_ code: String, _ language: String) -> String?
    private nonisolated(unsafe) static var codeRenderer: CodeRenderer?

    /// A complete HTML page for `markdown`. With `math`, `$…$` and `$$…$$` are written
    /// through it instead of staying as source.
    static func page(from markdown: String, title: String, math: MathRenderer? = nil, code: CodeRenderer? = nil,
                     scale: Double = 1) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(stylesheet(scale: scale))
        </style>
        </head>
        <body>
        \(body(from: markdown, math: math, code: code))
        </body>
        </html>
        """
    }

    /// The CSS of an exported page, in the style of Notion and Obsidian: shared by the export and the split view's
    /// preview, so the two look alike. `scale` sizes everything, as the PDF's Scale does.
    static func stylesheet(scale: Double = 1) -> String {
        """
        :root { color-scheme: light; }
        * { -webkit-print-color-adjust: exact; print-color-adjust: exact; }
        html { font-size: \(String(format: "%.2f", 16 * scale))px; }
        body { font-family: -apple-system, "SF Pro Text", "Helvetica Neue", Helvetica, Arial, sans-serif; line-height: 1.7; color: #37352f; max-width: 46em; margin: 0 auto; padding: 2em 1.5em; -webkit-font-smoothing: antialiased; }
        p { margin: 0.55em 0; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; font-weight: 650; color: #2b2a27; margin: 1.5em 0 0.4em; break-after: avoid; }
        h1 { font-size: 2.1em; font-weight: 700; margin-top: 0.8em; letter-spacing: -0.01em; }
        h2 { font-size: 1.6em; padding-bottom: 0.2em; border-bottom: 1px solid #ebeae6; }
        h3 { font-size: 1.3em; } h4 { font-size: 1.1em; } h5, h6 { font-size: 1em; color: #6b6a66; }
        a { color: #37352f; text-decoration: underline; text-decoration-color: rgba(55,53,47,0.4); text-underline-offset: 0.15em; }
        strong { font-weight: 650; }
        code { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 0.86em; color: #eb5757; background: rgba(135,131,120,0.15); padding: 0.15em 0.4em; border-radius: 0.3em; }
        pre { background: #f7f6f3; padding: 1em 1.2em; border-radius: 0.4em; overflow-wrap: anywhere; white-space: pre-wrap; margin: 0.9em 0; break-inside: avoid; }
        pre code { background: none; color: #37352f; padding: 0; font-size: 0.85em; line-height: 1.55; }
        blockquote { margin: 0.9em 0; padding: 0.1em 0 0.1em 1em; border-left: 0.2em solid #37352f; font-size: 1.05em; break-inside: avoid; }
        blockquote p { margin: 0.35em 0; }
        mark { background: #fdecc8; color: inherit; padding: 0.05em 0.15em; border-radius: 0.2em; }
        table { border-collapse: collapse; margin: 1em 0; width: 100%; break-inside: avoid; }
        th, td { border: 1px solid #e3e2de; padding: 0.45em 0.8em; text-align: left; vertical-align: top; }
        th { background: #f7f6f3; font-weight: 600; }
        ul, ol { padding-left: 1.6em; margin: 0.5em 0; }
        li { margin: 0.2em 0; }
        li.task { list-style: none; margin-left: -1.4em; }
        li.task .box { font-size: 1.15em; margin-right: 0.3em; }
        li.task.done .box { color: #2f80ed; }
        li.task.done { color: #8a8984; }
        img { max-width: 100%; break-inside: avoid; }
        hr { border: none; border-top: 1px solid #e3e2de; margin: 1.8em 0; }
        .callout { margin: 0.9em 0; padding: 0.8em 1em; border-radius: 0.5em; break-inside: avoid; background: rgba(8,109,221,0.10); --accent: #086ddd; }
        .callout-title { font-weight: 650; color: var(--accent); display: flex; align-items: center; gap: 0.5em; }
        .callout-body > :first-child { margin-top: 0.35em; } .callout-body > :last-child { margin-bottom: 0; }
        .callout-info { background: rgba(0,160,184,0.10); --accent: #00a0b8; }
        .callout-tip { background: rgba(0,165,140,0.10); --accent: #00a58c; }
        .callout-success { background: rgba(8,185,78,0.10); --accent: #08a845; }
        .callout-question { background: rgba(217,165,0,0.12); --accent: #b88700; }
        .callout-warning { background: rgba(236,117,0,0.12); --accent: #d96a00; }
        .callout-danger { background: rgba(233,49,71,0.10); --accent: #e93147; }
        .callout-example { background: rgba(120,82,238,0.10); --accent: #7852ee; }
        .callout-quote { background: rgba(158,158,158,0.12); --accent: #7a7a7a; }
        @page { margin: 18mm 16mm; }
        """
    }

    /// The body's HTML, without the page around it. With `annotated`, each
    /// block carries `data-line`, its 0-based source line (for the split view).
    static func body(from markdown: String, annotated: Bool = false, math: MathRenderer? = nil, code: CodeRenderer? = nil) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        mathRenderer = math
        codeRenderer = code
        defer { mathRenderer = nil; codeRenderer = nil }
        return blocks(&lines, base: 0, annotate: annotated)
    }

    // MARK: - Blocks

    private static func blocks(_ lines: inout [String], base: Int, annotate: Bool) -> String {
        func a(_ line: Int) -> String { annotate ? " data-line=\"\(base + line)\"" : "" }
        var out: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code.
            if let fence = fenceMarker(trimmed) {
                let language = String(trimmed.dropFirst(fence.count)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                let fenceLine = i
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i]); i += 1
                }
                i += 1
                let cls = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                let source = code.joined(separator: "\n")
                let body = codeRenderer?(source, language) ?? escape(source)
                out.append("<pre\(a(fenceLine))><code\(cls)>\(body)</code></pre>")
                continue
            }
            // Display math: `$$` on a line of its own, the formula, `$$`; or `$$ formula $$` on one line.
            if let render = mathRenderer, trimmed.hasPrefix("$$") {
                let mathStart = i
                var tex: String
                if trimmed.count >= 4, trimmed.hasSuffix("$$") {
                    tex = String(trimmed.dropFirst(2).dropLast(2))
                    i += 1
                } else {
                    var body: [String] = [String(trimmed.dropFirst(2))]
                    i += 1
                    while i < lines.count {
                        let t = lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                        if t.hasSuffix("$$") { body.append(String(t.dropLast(2))); break }
                        body.append(t)
                    }
                    tex = body.joined(separator: "\n")
                }
                tex = tex.trimmingCharacters(in: .whitespacesAndNewlines)
                out.append("<p style=\"text-align: center\"\(a(mathStart))>\(render(tex, true))</p>")
                continue
            }
            // Alignment wrapper, as the editor writes it: `<div align="center">`, the blocks, `</div>`.
            if let alignment = alignmentOpening(trimmed) {
                var inner: [String] = []
                let wrapperStart = i
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).lowercased() != "</div>" {
                    inner.append(lines[i]); i += 1
                }
                i += 1
                out.append("<div style=\"text-align: \(alignment)\"\(a(wrapperStart))>\(blocks(&inner, base: base + wrapperStart + 1, annotate: annotate))</div>")
                continue
            }
            // Heading.
            if let (level, text) = heading(trimmed) {
                out.append("<h\(level)\(a(i))>\(inline(text))</h\(level)>")
                i += 1; continue
            }
            // Rule.
            if isRule(trimmed) { out.append("<hr\(a(i))>"); i += 1; continue }
            // Quote.
            if trimmed.hasPrefix(">") {
                var inner: [String] = []
                let quoteStart = i
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var l = lines[i].trimmingCharacters(in: .whitespaces)
                    l.removeFirst()
                    if l.hasPrefix(" ") { l.removeFirst() }
                    inner.append(l); i += 1
                }
                if let callout = calloutHeader(inner.first) {
                    var rest = Array(inner.dropFirst())
                    let title = callout.title.isEmpty ? callout.defaultTitle : inline(callout.title)
                    out.append("<div class=\"callout callout-\(callout.style)\"\(a(quoteStart))><div class=\"callout-title\"><span class=\"callout-icon\">\(callout.icon)</span>\(title)</div>"
                        + "<div class=\"callout-body\">\(blocks(&rest, base: base + quoteStart + 1, annotate: annotate))</div></div>")
                } else {
                    out.append("<blockquote\(a(quoteStart))>\(blocks(&inner, base: base + quoteStart, annotate: annotate))</blockquote>")
                }
                continue
            }
            // Table: a header row followed by a separator row.
            if trimmed.contains("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                let header = cells(of: trimmed)
                let tableStart = i
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(of: lines[i])); i += 1
                }
                var html = "<table\(a(tableStart))><thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                for row in rows { html += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>" }
                out.append(html + "</tbody></table>")
                continue
            }
            // List.
            if listItem(line) != nil {
                out.append(list(&lines, &i, base: base, annotate: annotate))
                continue
            }
            // Paragraph: until a blank line or the start of another block.
            var para: [String] = []
            let paraStart = i
            while i < lines.count {
                let l = lines[i], t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || fenceMarker(t) != nil || heading(t) != nil || isRule(t) || t.hasPrefix(">")
                    || (listItem(l) != nil && !para.isEmpty) { break }
                para.append(t); i += 1
            }
            out.append("<p\(a(paraStart))>\(inline(para.joined(separator: "\n")).replacingOccurrences(of: "\n", with: "<br>\n"))</p>")
        }
        return out.joined(separator: "\n")
    }

    /// An Obsidian callout's first line: `[!note] Optional title` (a `+` or `-` after the kind, for folding, is ignored).
    private struct CalloutHeader { let style: String; let icon: String; let title: String; let defaultTitle: String }

    private static func calloutHeader(_ line: String?) -> CalloutHeader? {
        guard let line, let regex = try? NSRegularExpression(pattern: "^\\[!([A-Za-z]+)\\][+-]?[ \\t]*(.*)$") else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        let ns = t as NSString
        guard let match = regex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let kind = ns.substring(with: match.range(at: 1)).lowercased()
        let title = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
        let style: String, icon: String
        switch kind {
        case "note": (style, icon) = ("note", "📝")
        case "abstract", "summary", "tldr", "info", "todo": (style, icon) = ("info", "ℹ️")
        case "tip", "hint", "important": (style, icon) = ("tip", "💡")
        case "success", "check", "done": (style, icon) = ("success", "✅")
        case "question", "help", "faq": (style, icon) = ("question", "❓")
        case "warning", "caution", "attention": (style, icon) = ("warning", "⚠️")
        case "failure", "fail", "missing", "danger", "error", "bug": (style, icon) = ("danger", "🔥")
        case "example": (style, icon) = ("example", "📋")
        case "quote", "cite": (style, icon) = ("quote", "❝")
        default: (style, icon) = ("note", "📝")
        }
        return CalloutHeader(style: style, icon: icon, title: title, defaultTitle: kind.prefix(1).uppercased() + kind.dropFirst())
    }

    /// The alignment an opening wrapper line sets (`<div align="center">`), if `trimmed` is one.
    private static func alignmentOpening(_ trimmed: String) -> String? {
        let lower = trimmed.lowercased()
        for alignment in ["left", "center", "right", "justify"] where lower == "<div align=\"\(alignment)\">" {
            return alignment
        }
        return nil
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) { return marker }
        return nil
    }

    private static func heading(_ trimmed: String) -> (Int, String)? {
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " else { return nil }
        var text = trimmed.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    private static func cells(of line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Lists

    private struct Item { let indent: Int; let ordered: Bool; let text: String }

    private static func listItem(_ line: String) -> Item? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let t = line.trimmingCharacters(in: .whitespaces)
        if let first = t.first, "-*+".contains(first), t.dropFirst().first == " " {
            return Item(indent: indent, ordered: false, text: String(t.dropFirst(2)))
        }
        let digits = t.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 10, t.dropFirst(digits.count).hasPrefix(". ") || t.dropFirst(digits.count).hasPrefix(") ") {
            return Item(indent: indent, ordered: true, text: String(t.dropFirst(digits.count + 2)))
        }
        return nil
    }

    private static func list(_ lines: inout [String], _ i: inout Int, base lineBase: Int, annotate: Bool) -> String {
        guard let first = listItem(lines[i]) else { return "" }
        let base = first.indent
        let tag = first.ordered ? "ol" : "ul"
        var html = "<\(tag)>"
        while i < lines.count, let item = listItem(lines[i]), item.indent >= base {
            if item.indent > base {
                html += list(&lines, &i, base: lineBase, annotate: annotate)   // a nested list inside the previous item
                continue
            }
            var text = item.text
            var checkbox = ""
            var itemClass = ""
            if text.hasPrefix("[ ] ") { checkbox = "<span class=\"box\">☐</span>"; itemClass = " class=\"task\""; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { checkbox = "<span class=\"box\">☑</span>"; itemClass = " class=\"task done\""; text.removeFirst(4) }
            let itemLine = i
            i += 1
            var nested = ""
            if i < lines.count, let next = listItem(lines[i]), next.indent > base { nested = list(&lines, &i, base: lineBase, annotate: annotate) }
            html += "<li\(itemClass)\(annotate ? " data-line=\"\(lineBase + itemLine)\"" : "")>\(checkbox)\(inline(text))\(nested)</li>"
        }
        return html + "</\(tag)>"
    }

    // MARK: - Inline

    static func inline(_ text: String) -> String {
        var s = escape(text)
        // Inline code first, so its contents are left alone.
        var codes: [String] = []
        s = replace(s, pattern: "`([^`\n]+)`") { m in codes.append("<code>\(m[1])</code>"); return "\u{1}\(codes.count - 1)\u{1}" }
        // Inline math, taken out whole before the emphasis rules can read its `_` and `*`.
        var maths: [String] = []
        if let render = mathRenderer {
            s = replace(s, pattern: "(?<![\\\\$])\\$(?![\\s$])([^$\\n]+?)(?<![\\s\\\\])\\$(?!\\d)") { m in
                maths.append(render(unescaped(m[1]), false))
                return "\u{2}\(maths.count - 1)\u{2}"
            }
        }
        s = replace(s, pattern: "!\\[([^\\]]*)\\]\\(([^)\\s]+)(?:\\s+&quot;([^&]*)&quot;)?\\)") { m in
            "<img src=\"\(m[2])\" alt=\"\(m[1])\">"
        }
        s = replace(s, pattern: "\\[([^\\]]+)\\]\\(([^)\\s]+)(?:\\s+&quot;([^&]*)&quot;)?\\)") { m in
            "<a href=\"\(m[2])\">\(m[1])</a>"
        }
        s = replace(s, pattern: "\\*\\*\\*([^*]+)\\*\\*\\*") { "<strong><em>\($0[1])</em></strong>" }
        s = replace(s, pattern: "\\*\\*([^*]+)\\*\\*|__([^_]+)__") { "<strong>\($0[1].isEmpty ? $0[2] : $0[1])</strong>" }
        s = replace(s, pattern: "(?<![\\w*])\\*([^*\n]+)\\*(?![\\w*])|(?<![\\w_])_([^_\n]+)_(?![\\w_])") {
            "<em>\($0[1].isEmpty ? $0[2] : $0[1])</em>"
        }
        s = replace(s, pattern: "~~([^~]+)~~") { "<del>\($0[1])</del>" }
        s = replace(s, pattern: "==([^=\n]+)==") { "<mark>\($0[1])</mark>" }
        // Colour, as the editor writes it: `<span style="color: #rrggbb">…</span>` and
        // `<mark style="background: #rrggbb">…</mark>`. Only a hex colour is let through into the style.
        s = replace(s, pattern: "&lt;span style=&quot;color: ?(#[0-9A-Fa-f]{6})&quot;&gt;(.*?)&lt;/span&gt;") {
            "<span style=\"color: \($0[1])\">\($0[2])</span>"
        }
        s = replace(s, pattern: "&lt;mark style=&quot;background: ?(#[0-9A-Fa-f]{6})&quot;&gt;(.*?)&lt;/mark&gt;") {
            "<mark style=\"background-color: \($0[1])\">\($0[2])</mark>"
        }
        // Arrows, as the editor types them: `->` `<-` `<->` (escaped by now, as the rest of the text is).
        s = s.replacingOccurrences(of: "&lt;-&gt;", with: "↔").replacingOccurrences(of: "-&gt;", with: "→")
            .replacingOccurrences(of: "&lt;-", with: "←")
        for (index, code) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{1}\(index)\u{1}", with: code) }
        for (index, math) in maths.enumerated() { s = s.replacingOccurrences(of: "\u{2}\(index)\u{2}", with: math) }
        return s
    }

    private static func unescaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func replace(_ text: String, pattern: String, _ transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }
}
