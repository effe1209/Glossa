//
//  MarkdownHTML.swift
//  PageFlow
//
//  A small Markdown-to-HTML converter for exporting: headings, paragraphs,
//  emphasis, code, links, images, quotes, lists (nested, with task items),
//  tables and rules. Pure text in, text out.
//

import Foundation

enum MarkdownHTML {
    /// A complete HTML page for `markdown`.
    static func page(from markdown: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body { font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 15px; line-height: 1.6; color: #1d1d1f; max-width: 760px; margin: 2em auto; padding: 0 1em; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 0.5em; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
        code { font-family: Menlo, Consolas, monospace; font-size: 0.9em; background: #f2f2f4; padding: 0.1em 0.3em; border-radius: 3px; }
        pre { background: #f2f2f4; padding: 0.8em 1em; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 1em 0; padding: 0 1em; border-left: 3px solid #c7c7cc; color: #555; }
        table { border-collapse: collapse; margin: 1em 0; }
        th, td { border: 1px solid #d1d1d6; padding: 0.4em 0.8em; text-align: left; }
        th { background: #f2f2f4; }
        img { max-width: 100%; }
        hr { border: none; border-top: 1px solid #d1d1d6; margin: 2em 0; }
        a { color: #0a60d8; }
        </style>
        </head>
        <body>
        \(body(from: markdown))
        </body>
        </html>
        """
    }

    /// The body's HTML, without the page around it. With `annotated`, each
    /// block carries `data-line`, its 0-based source line (for the split view).
    static func body(from markdown: String, annotated: Bool = false) -> String {
        var lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
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
                out.append("<pre\(a(fenceLine))><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>")
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
                out.append("<blockquote\(a(quoteStart))>\(blocks(&inner, base: base + quoteStart, annotate: annotate))</blockquote>")
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
            if text.hasPrefix("[ ] ") { checkbox = "☐ "; text.removeFirst(4) }
            else if text.lowercased().hasPrefix("[x] ") { checkbox = "☑ "; text.removeFirst(4) }
            let itemLine = i
            i += 1
            var nested = ""
            if i < lines.count, let next = listItem(lines[i]), next.indent > base { nested = list(&lines, &i, base: lineBase, annotate: annotate) }
            html += "<li\(annotate ? " data-line=\"\(lineBase + itemLine)\"" : "")>\(checkbox)\(inline(text))\(nested)</li>"
        }
        return html + "</\(tag)>"
    }

    // MARK: - Inline

    static func inline(_ text: String) -> String {
        var s = escape(text)
        // Inline code first, so its contents are left alone.
        var codes: [String] = []
        s = replace(s, pattern: "`([^`\n]+)`") { m in codes.append("<code>\(m[1])</code>"); return "\u{1}\(codes.count - 1)\u{1}" }
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
        for (index, code) in codes.enumerated() { s = s.replacingOccurrences(of: "\u{1}\(index)\u{1}", with: code) }
        return s
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
