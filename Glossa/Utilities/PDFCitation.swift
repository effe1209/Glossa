//
//  PDFCitation.swift
//  PageFlow
//
//  A passage quoted from a PDF into a note, and the link that takes the reader
//  back to it. The link is an ordinary relative Markdown link to the PDF, so
//  any editor can follow it and the note editor's existing local-link path
//  carries it:
//
//      > The extracted text.
//      > — [Document title, p. 12](Papers/doc.pdf#page=12&gid=3fa9c1d2e4b50a77&q=The%20extracted)
//
//  `page` is the 1-based page (`PDFPageLink` reads it), `gid` is the document's
//  stable identity (`PDFDocumentFingerprint`), which finds the file again when
//  the path no longer does, and `q` is the start of the passage, which lets
//  the reader mark it on the page.
//

import Foundation

nonisolated struct PDFCitation: Equatable, Sendable {
    var title: String
    /// 1-based.
    var page: Int
    /// The PDF as the link writes it: a path relative to the note, or a `file:` URL.
    var path: String
    var documentID: String
    var quote: String
    /// The passage's UTF-16 range in the page's text, as PDFKit counts it; lets the
    /// reader mark the whole passage exactly. Absent for a quote made without one.
    var range: NSRange? = nil

    /// Characters of the passage a link keeps for finding it on the page.
    static let snippetLength = 80

    // MARK: Writing

    /// The quote and its attribution, ready to insert at a caret: a blank line
    /// above and below keep it a block of its own.
    func markdown() -> String {
        let lines = Self.normalizedQuote(quote)
        var out = ""
        for line in lines { out += "> " + Self.escapingBlockMarkup(line) + "\n" }
        if !lines.isEmpty { out += ">\n" }
        out += "> — [\(Self.escapingLinkText(label)), p. \(page)](\(target))\n"
        return out
    }

    /// The name shown in the link: the document's title, or its file name.
    private var label: String { title.isEmpty ? "PDF" : title }

    /// `path#page=…&gid=…&q=…`
    var target: String {
        var fragment = "page=\(page)&gid=\(documentID)"
        let snippet = Self.snippet(of: quote)
        if !snippet.isEmpty, let encoded = snippet.addingPercentEncoding(withAllowedCharacters: Self.valueAllowed) {
            fragment += "&q=" + encoded
        }
        if let range, range.location >= 0, range.length > 0 { fragment += "&r=\(range.location)-\(range.length)" }
        return Self.encodedPath(path) + "#" + fragment
    }

    // MARK: Reading

    /// What a clicked citation link says; nil for any link that is not one.
    struct Reference: Equatable, Sendable {
        var path: String
        var page: Int
        var documentID: String
        var snippet: String?
        /// Where the passage sits in the page's text (location, length), if the link says.
        var range: NSRange?

        /// A link taken from the note: the path, or `file:` URL, and its fragment.
        init?(link: URL) {
            guard let components = URLComponents(url: link, resolvingAgainstBaseURL: false),
                  let fragment = components.percentEncodedFragment else { return nil }
            self.init(path: components.path, fragment: fragment)
        }

        init?(path: String, fragment: String) {
            var page: Int?, id: String?, snippet: String?, range: NSRange?
            for pair in fragment.split(separator: "&", omittingEmptySubsequences: true) {
                guard let equals = pair.firstIndex(of: "=") else { continue }
                let key = pair[..<equals]
                let value = String(pair[pair.index(after: equals)...]).removingPercentEncoding ?? ""
                switch key {
                case "page" where page == nil: page = PDFPageLink.pageIndex(in: "page=" + value).map { $0 + 1 }
                case "gid" where id == nil: id = PDFCitation.isValidID(value) ? value : nil
                case "q" where snippet == nil: snippet = value.isEmpty ? nil : value
                case "r" where range == nil:
                    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
                    if parts.count == 2, let location = Int(parts[0]), let length = Int(parts[1]), location >= 0, length > 0 {
                        range = NSRange(location: location, length: length)
                    }
                default: break
                }
            }
            guard let page, let id, !path.isEmpty else { return nil }
            self.path = path
            self.page = page
            self.documentID = id
            self.snippet = snippet
            self.range = range
        }
    }

    /// Every citation in a note's text, in order: its link text and what it points at.
    static func references(in markdown: String) -> [(label: String, reference: Reference)] {
        guard markdown.contains("gid=") else { return [] }
        var found: [(String, Reference)] = []
        for match in linkPattern.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
            guard let text = Range(match.range(at: 1), in: markdown),
                  let target = Range(match.range(at: 2), in: markdown),
                  let hash = markdown[target].firstIndex(of: "#"),
                  let reference = Reference(path: String(markdown[target][..<hash]).removingPercentEncoding ?? "",
                                            fragment: String(markdown[target][markdown[target].index(after: hash)...]))
            else { continue }
            found.append((String(markdown[text]), reference))
        }
        return found
    }

    private static let linkPattern = try! NSRegularExpression(pattern: #"\[((?:\\.|[^\]\\])*)\]\(([^)\s]+)\)"#)

    // MARK: Identity text

    static let idLength = 16

    static func isValidID(_ text: String) -> Bool {
        text.utf8.count == idLength && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    // MARK: Paths

    /// How a note writes the PDF: relative to its own folder when it has one
    /// and the file is in the same tree, otherwise a `file:` URL.
    static func linkPath(to pdf: URL, from noteFolder: URL?) -> String {
        let file = pdf.standardizedFileURL
        guard let folder = noteFolder?.standardizedFileURL else { return file.absoluteString }
        return relativePath(from: folder, to: file)
    }

    static func relativePath(from folder: URL, to file: URL) -> String {
        let from = folder.pathComponents, to = file.pathComponents
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        guard common > 1 else { return file.absoluteString }   // no common ancestor below "/"
        let up = Array(repeating: "..", count: from.count - common)
        return (up + to[common...]).joined(separator: "/")
    }

    private static func encodedPath(_ path: String) -> String {
        if path.hasPrefix("file:") { return path.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29") }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static let segmentAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~@,+!$'*"))
    private static let valueAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    // MARK: Text

    /// The passage as quote lines: one paragraph per blank-line break, line
    /// breaks inside a paragraph joined (a PDF breaks lines where the page
    /// does), hyphenation at a line end healed.
    static func normalizedQuote(_ text: String) -> [String] {
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { paragraph -> String in
                var joined = ""
                for raw in paragraph.split(separator: "\n", omittingEmptySubsequences: true) {
                    let line = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
                    guard !line.isEmpty else { continue }
                    if joined.hasSuffix("-"), let first = line.first, first.isLowercase,
                       let before = joined.dropLast().last, before.isLetter {
                        joined.removeLast()
                    } else if !joined.isEmpty {
                        joined += " "
                    }
                    joined += line
                }
                return joined
            }
            .filter { !$0.isEmpty }
        var lines: [String] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { lines.append("") }
            lines.append(paragraph)
        }
        return lines
    }

    /// The start of the passage, whole words, for the link.
    static func snippet(of text: String) -> String {
        let flat = normalizedQuote(text).filter { !$0.isEmpty }.first ?? ""
        guard flat.count > snippetLength else { return flat }
        let cut = flat.prefix(snippetLength)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > snippetLength / 2 {
            return String(cut[..<space])
        }
        return String(cut)
    }

    /// A line that begins like block markup would turn the quote into a heading
    /// or a list: a backslash keeps it text.
    static func escapingBlockMarkup(_ line: String) -> String {
        guard let first = line.first else { return line }
        if "#-+*>".contains(first) || first == "|" { return "\\" + line }
        var digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9, line.dropFirst(digits.count).first.map({ $0 == "." || $0 == ")" }) == true {
            digits = digits.prefix(digits.count)
            return String(digits) + "\\" + line.dropFirst(digits.count)
        }
        return line
    }

    static func escapingLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
