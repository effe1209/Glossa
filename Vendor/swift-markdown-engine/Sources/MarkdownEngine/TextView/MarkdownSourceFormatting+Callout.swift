//
//  MarkdownSourceFormatting+Callout.swift
//  MarkdownEngine
//
//  Callouts, as Obsidian writes them: a quote whose first line names its kind,
//
//      > [!tip] Optional title
//      > The callout's text.
//
//  The editor draws the bar and title in the kind's colour; other Markdown readers
//  show a plain quote with the marker.
//

import Foundation

/// The callout kinds the editor offers (any other word after `[!` is drawn as a note).
public enum MarkdownCallout {
    public struct Kind: Sendable, Equatable {
        public let id: String
        public let title: String
        public let symbol: String
    }

    public static let kinds: [Kind] = [
        Kind(id: "note", title: "Note", symbol: "pencil"),
        Kind(id: "tip", title: "Tip", symbol: "lightbulb"),
        Kind(id: "info", title: "Info", symbol: "info.circle"),
        Kind(id: "success", title: "Success", symbol: "checkmark.circle"),
        Kind(id: "question", title: "Question", symbol: "questionmark.circle"),
        Kind(id: "warning", title: "Warning", symbol: "exclamationmark.triangle"),
        Kind(id: "danger", title: "Danger", symbol: "flame"),
        Kind(id: "example", title: "Example", symbol: "list.bullet.rectangle"),
        Kind(id: "quote", title: "Quote", symbol: "quote.opening"),
    ]
}

extension MarkdownSourceFormatting {
    private static let calloutHeader = try! NSRegularExpression(pattern: #"^([ \t]*>[ \t]*)\[!([A-Za-z]+)\]"#)

    /// Makes the lines the selection touches a callout of `kind`: a header line `> [!kind]` above them, each
    /// line a quote line. On lines that already are a callout it changes the kind instead. A blank line
    /// becomes an empty callout with the caret in its body.
    static func insertCallout(kind: String, in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let kind = kind.lowercased().filter { $0.isLetter }
        guard !kind.isEmpty else { return nil }
        let lastLocation = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        func line(at location: Int) -> NSRange {
            text.lineRange(for: NSRange(location: min(location, max(0, text.length - (text.length == 0 ? 0 : 1))), length: 0))
        }
        let span = NSUnionRange(line(at: selection.location), line(at: max(selection.location, lastLocation)))

        // Already a callout: the header line is the span's first line, or the quote's above it.
        var header = span
        while header.location > 0 {
            let previous = text.lineRange(for: NSRange(location: header.location - 1, length: 0))
            guard text.substring(with: previous).trimmingCharacters(in: .whitespaces).hasPrefix(">") else { break }
            header = previous
        }
        let headerLine = text.substring(with: header)
        let headerRange = NSRange(location: 0, length: (headerLine as NSString).length)
        if let match = calloutHeader.firstMatch(in: headerLine, range: headerRange) {
            let kindRange = NSRange(location: header.location + match.range(at: 2).location, length: match.range(at: 2).length)
            let shift = kind.utf16.count - kindRange.length
            return MarkdownSourceEdit(range: kindRange, replacement: kind,
                                      selection: NSRange(location: selection.location + (selection.location > kindRange.location ? shift : 0),
                                                         length: selection.length))
        }

        let lines = splitLines(text.substring(with: span))
        let isBlank = lines.allSatisfy { $0.content.trimmingCharacters(in: .whitespaces).isEmpty }
        let terminator = lines.last?.terminator ?? ""
        if isBlank {
            let replacement = "> [!\(kind)]\n> " + terminator
            return MarkdownSourceEdit(range: span, replacement: replacement,
                                      selection: NSRange(location: span.location + ("> [!\(kind)]\n> " as NSString).length, length: 0))
        }
        // Lines already quoted keep their markers; the rest take one.
        let body = lines.map { line -> String in
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            let quoted = trimmed.hasPrefix(">") ? line.content : "> " + line.content
            return quoted + line.terminator
        }.joined()
        let replacement = "> [!\(kind)]\n" + body
        let caret = span.location + (replacement as NSString).length - (terminator as NSString).length
        return MarkdownSourceEdit(range: span, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }
}
