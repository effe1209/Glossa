//
//  MarkdownColorStyling.swift
//  MarkdownEngine
//
//  Draws the colour spans of `MarkdownColorPalette`: the words in their colour (or on their
//  highlight), the tags around them always hidden. (They can't follow the caret in and out: only the
//  paragraphs being edited are restyled, so a tag shown for the caret would stay shown after it left.
//  The colour menu works with the caret anywhere in the span, so the tags are never needed.)
//

import AppKit

enum MarkdownColorStyling {
    private static let pattern = try! NSRegularExpression(
        pattern: "<(span|mark) style=\"(?:color|background): ?(#[0-9A-Fa-f]{6})\">")

    /// `ranges` with every colour span styled. Cheap when the note has none.
    static func applying(
        to ranges: [StyledRange],
        text: String,
        hiddenFont: NSFont
    ) -> [StyledRange] {
        let ns = text as NSString
        guard ns.range(of: "<span style=\"color").location != NSNotFound
            || ns.range(of: "<mark style=\"background").location != NSNotFound else { return ranges }

        let fences = MarkdownAlignmentStyling.fencedRanges(in: ns)
        var result = ranges
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let open = match.range
            if fences.contains(where: { NSLocationInRange(open.location, $0) }) { continue }
            let isText = ns.substring(with: match.range(at: 1)) == "span"
            let line = ns.lineRange(for: open)
            let after = NSMaxRange(open)
            let close = ns.range(of: isText ? "</span>" : "</mark>", options: [],
                                 range: NSRange(location: after, length: NSMaxRange(line) - after))
            guard close.location != NSNotFound,
                  let color = MarkdownColorPalette.Swatch(name: "", hex: ns.substring(with: match.range(at: 2))).colorIfValid else { continue }
            // Inside an inline code span the tag is the writer's text, not a colour.
            let before = ns.substring(with: NSRange(location: line.location, length: open.location - line.location))
            if before.filter({ $0 == "`" }).count % 2 == 1 { continue }

            let content = NSRange(location: after, length: close.location - after)
            if content.length > 0 {
                if isText {
                    result.append((content, [.foregroundColor: color]))
                } else {
                    // Black text on the marker, whatever the editor's appearance: the colours are light.
                    result.append((content, [.backgroundColor: color, .foregroundColor: NSColor.black]))
                }
            }
            let tagStyle: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.clear, .font: hiddenFont]
            result.append((open, tagStyle))
            result.append((close, tagStyle))
        }
        return result
    }
}

private extension MarkdownColorPalette.Swatch {
    /// The colour, or nil when the hex isn't one.
    var colorIfValid: NSColor? {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, UInt32(digits, radix: 16) != nil else { return nil }
        return color
    }
}
