//
//  MarkdownSourceFormatting+Math.swift
//  MarkdownEngine
//
//  Inserting formulas. Inline math is `$…$` around the selection; display math
//  is a block of its own,
//
//      $$
//      formula
//      $$
//
//  Both are plain source, so they save and reopen as they are and any other
//  Markdown reader sees them. Each toggles: applied to a formula it unwraps it.
//

import Foundation

extension MarkdownSourceFormatting {
    private static let dollar: unichar = 0x24
    private static let newline: unichar = 0x0A

    // MARK: Inline

    /// `$…$` around the selection, with the selection left on the formula so typing
    /// replaces it; an empty selection inserts a pair with the caret between. On a
    /// selection already in a pair (inside it, or including it) it removes the pair.
    /// A selection across lines is left alone: inline math is one line.
    static func toggleInlineMath(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        let selected = text.substring(with: selection)
        guard !selected.contains("\n"), !selected.contains("\r") else { return nil }

        // Inside a pair: `$` right outside each end, and not the halves of `$$`.
        if selection.length > 0, selection.location > 0, NSMaxRange(selection) < text.length,
           text.character(at: selection.location - 1) == dollar, text.character(at: NSMaxRange(selection)) == dollar,
           !isDollar(at: selection.location - 2, in: text), !isDollar(at: NSMaxRange(selection) + 1, in: text) {
            return MarkdownSourceEdit(
                range: NSRange(location: selection.location - 1, length: selection.length + 2), replacement: selected,
                selection: NSRange(location: selection.location - 1, length: selection.length))
        }
        // Including the pair: `$x$` selected whole.
        let units = selected as NSString
        if units.length >= 3, units.character(at: 0) == dollar, units.character(at: units.length - 1) == dollar,
           units.character(at: 1) != dollar, units.character(at: units.length - 2) != dollar {
            let inner = units.substring(with: NSRange(location: 1, length: units.length - 2))
            return MarkdownSourceEdit(range: selection, replacement: inner,
                                      selection: NSRange(location: selection.location, length: (inner as NSString).length))
        }

        guard selection.length > 0 else {
            return MarkdownSourceEdit(range: selection, replacement: "$$",
                                      selection: NSRange(location: selection.location + 1, length: 0))
        }
        // The delimiters hug the formula: space the selection carries stays outside them.
        let leading = selected.prefix { $0 == " " || $0 == "\t" }.utf16.count
        let trailing = selected.reversed().prefix { $0 == " " || $0 == "\t" }.count
        let contentLength = (selected as NSString).length - leading - trailing
        guard contentLength > 0 else {
            return MarkdownSourceEdit(range: selection, replacement: "$$",
                                      selection: NSRange(location: selection.location + 1, length: 0))
        }
        let content = units.substring(with: NSRange(location: leading, length: contentLength))
        let replacement = String(repeating: " ", count: leading) + "$" + content + "$" + String(repeating: " ", count: trailing)
        return MarkdownSourceEdit(range: selection, replacement: replacement,
                                  selection: NSRange(location: selection.location + leading + 1, length: contentLength))
    }

    // MARK: Display

    /// A `$$` block around the selection (or an empty one at the caret), set apart by
    /// blank lines; the selection lands on the formula. The selection's own words
    /// become the formula, even from the middle of a line, which splits around it.
    /// On a selection inside a `$$` block, or the block's lines, it removes the block.
    static func toggleDisplayMath(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        if let unwrap = displayMathUnwrap(in: text, selection: selection) { return unwrap }

        let selected = text.substring(with: selection)
        let body = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyLength = (body as NSString).length

        // The span replaced: the selection, widened to its line's start when only space precedes it
        // and to its line's end when only space follows, so no blank remnant of the line is left.
        var start = selection.location
        var end = NSMaxRange(selection)
        let startLine = text.lineRange(for: NSRange(location: start, length: 0))
        let prefix = text.substring(with: NSRange(location: startLine.location, length: start - startLine.location))
        let prefixIsBlank = prefix.trimmingCharacters(in: .whitespaces).isEmpty
        if prefixIsBlank { start = startLine.location }
        else {
            // The text before keeps no trailing space after the split.
            while start > startLine.location, [0x20, 0x09].contains(text.character(at: start - 1)) { start -= 1 }
        }

        var lineContentEnd = 0
        text.getLineStart(nil, end: nil, contentsEnd: &lineContentEnd, for: NSRange(location: end, length: 0))
        let suffix = text.substring(with: NSRange(location: end, length: max(0, lineContentEnd - end)))
        let suffixIsBlank = suffix.trimmingCharacters(in: .whitespaces).isEmpty
        if suffixIsBlank { end = lineContentEnd }
        else {
            // ...and the text after starts without leading space.
            while end < lineContentEnd, [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
        }

        // Blank lines keep the block from merging with its neighbours.
        let before: String
        if start == 0 { before = "" }
        else if prefixIsBlank { before = start >= 2 && text.character(at: start - 2) == newline ? "" : "\n" }
        else { before = "\n\n" }
        let after: String
        if end >= text.length { after = "" }
        else if !suffixIsBlank { after = "\n\n" }
        else {
            // `end` is on the line break; one more break after it is a blank line already.
            let nextLine = end + 1
            after = nextLine >= text.length || text.character(at: nextLine) == newline ? "" : "\n"
        }

        let replacement = before + "$$\n" + body + "\n$$" + after
        let bodyStart = start + (before as NSString).length + 3
        return MarkdownSourceEdit(range: NSRange(location: start, length: end - start), replacement: replacement,
                                  selection: NSRange(location: bodyStart, length: bodyLength))
    }

    /// The block `$$ … $$` the selection is in or spans, without its two delimiter lines.
    /// Blocks are found by pairing the lines that hold only `$$`, from the top, so a closing
    /// line is never taken for an opening one.
    private static func displayMathUnwrap(in text: NSString, selection: NSRange) -> MarkdownSourceEdit? {
        var open: NSRange?
        var location = 0
        while location < text.length {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(line)
            guard text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) == "$$" else { continue }
            guard let opening = open else { open = line; continue }
            open = nil
            let block = NSRange(location: opening.location, length: NSMaxRange(line) - opening.location)
            guard selection.location >= block.location, NSMaxRange(selection) <= NSMaxRange(block) else {
                if opening.location > NSMaxRange(selection) { return nil }
                continue
            }
            let innerRange = NSRange(location: NSMaxRange(opening), length: line.location - NSMaxRange(opening))
            let inner = text.substring(with: innerRange).trimmingCharacters(in: .newlines)
            let closeBreak = text.substring(with: line).hasSuffix("\n") ? "\n" : ""
            return MarkdownSourceEdit(range: block, replacement: inner + closeBreak,
                                      selection: NSRange(location: block.location, length: (inner as NSString).length))
        }
        return nil
    }

    private static func isDollar(at index: Int, in text: NSString) -> Bool {
        index >= 0 && index < text.length && text.character(at: index) == dollar
    }
}
