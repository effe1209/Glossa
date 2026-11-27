//
//  MarkdownSourceFormatting+Color.swift
//  MarkdownEngine
//
//  Colouring text and highlighting it, as plain HTML in the source (see
//  `MarkdownColorPalette`). A span is one line's inline run, never across a line break.
//

import Foundation

extension MarkdownSourceFormatting {
    /// A colour span found in the source: its opening tag, its closing tag, and its colour.
    struct ColorSpan: Equatable {
        let open: NSRange
        let close: NSRange
        let hex: String
        var whole: NSRange { NSRange(location: open.location, length: NSMaxRange(close) - open.location) }
        var content: NSRange { NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)) }
    }

    private static func tags(for kind: MarkdownColorKind) -> (name: String, property: String) {
        kind == .text ? ("span", "color") : ("mark", "background")
    }

    private static func openTag(_ kind: MarkdownColorKind, _ hex: String) -> String {
        let (name, property) = tags(for: kind)
        return "<\(name) style=\"\(property): \(hex.uppercased())\">"
    }

    /// Every colour span of `kind` on `line`, in order.
    static func colorSpans(of kind: MarkdownColorKind, in text: NSString, line: NSRange) -> [ColorSpan] {
        let (name, property) = tags(for: kind)
        guard let regex = try? NSRegularExpression(pattern: "<\(name) style=\"\(property): ?(#[0-9A-Fa-f]{6})\">") else { return [] }
        let closeTag = "</\(name)>"
        var spans: [ColorSpan] = []
        for match in regex.matches(in: text as String, range: line) {
            let after = NSMaxRange(match.range)
            let close = text.range(of: closeTag, options: [], range: NSRange(location: after, length: NSMaxRange(line) - after))
            guard close.location != NSNotFound else { continue }
            spans.append(ColorSpan(open: match.range, close: close, hex: text.substring(with: match.range(at: 1)).uppercased()))
        }
        return spans
    }

    /// The span of `kind` the selection is in (inside it, or exactly it).
    static func colorSpan(of kind: MarkdownColorKind, containing selection: NSRange, in text: NSString) -> ColorSpan? {
        guard selection.location <= text.length else { return nil }
        let line = text.lineRange(for: NSRange(location: min(selection.location, max(0, text.length - 1)), length: 0))
        return colorSpans(of: kind, in: text, line: line).first { span in
            (selection.location >= NSMaxRange(span.open) && NSMaxRange(selection) <= span.close.location)
                || NSEqualRanges(selection, span.whole)
        }
    }

    /// Gives the selection `hex` (`#RRGGBB`), or takes the colour off with nil. On text already coloured it
    /// changes that span's colour (the same colour again removes it); otherwise it wraps the selection.
    /// Nothing happens to an empty selection or one across lines: a colour is a run of text on one line.
    static func setColor(_ hex: String?, kind: MarkdownColorKind, in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let name = tags(for: kind).name
        if let span = colorSpan(of: kind, containing: selection, in: text) {
            let inner = text.substring(with: span.content)
            let unwrap = MarkdownSourceEdit(range: span.whole, replacement: inner,
                                            selection: NSRange(location: span.whole.location, length: (inner as NSString).length))
            guard let hex, hex.uppercased() != span.hex else { return unwrap }
            let tag = openTag(kind, hex)
            let shift = (tag as NSString).length - span.open.length
            return MarkdownSourceEdit(range: span.open, replacement: tag,
                                      selection: NSRange(location: max(span.open.location, selection.location + shift), length: selection.length))
        }
        guard let hex, selection.length > 0 else { return nil }
        let selected = text.substring(with: selection)
        guard !selected.contains("\n"), !selected.contains("\r") else { return nil }
        let tag = openTag(kind, hex)
        return MarkdownSourceEdit(range: selection, replacement: tag + selected + "</\(name)>",
                                  selection: NSRange(location: selection.location + (tag as NSString).length, length: selection.length))
    }
}
