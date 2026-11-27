//
//  PseudoCodeHighlighter.swift
//  MarkdownEngineCodeBlocks
//
//  Colours for code that names no language: pseudo-code, notes, snippets. It reads the
//  few things nearly every language shares (comments, strings, numbers, the common
//  keywords, calls) with one pass and no grammar, so it costs nothing per keystroke
//  and never paints a block in the wrong language's colours.
//

import AppKit
import Foundation

enum PseudoCodeHighlighter {
    // The One Light / One Dark palette the named languages use, so a block reads alike
    // whether or not its fence names a language.
    private static let keyword = dynamic(light: 0xA626A4, dark: 0xC678DD)
    private static let string = dynamic(light: 0x50A14F, dark: 0x98C379)
    private static let number = dynamic(light: 0x986801, dark: 0xD19A66)
    private static let comment = dynamic(light: 0x9A9BA2, dark: 0x7F848E)
    private static let call = dynamic(light: 0x4078F2, dark: 0x61AFEF)

    private static let keywords: Set<String> = [
        "if", "else", "elif", "elseif", "then", "end", "endif", "for", "foreach", "while", "do", "repeat", "until", "loop",
        "return", "break", "continue", "function", "func", "fn", "def", "procedure", "algorithm", "class", "struct", "enum",
        "interface", "let", "var", "const", "import", "from", "export", "public", "private", "protected", "static", "void",
        "int", "float", "double", "string", "bool", "boolean", "true", "false", "null", "nil", "none", "and", "or", "not",
        "in", "is", "switch", "case", "default", "try", "catch", "finally", "throw", "new", "self", "this", "to", "downto",
        "begin", "print", "input", "read", "write", "set", "get", "each", "with", "as", "async", "await", "yield", "lambda",
    ]

    static func highlight(_ code: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code)
        let text = code as NSString
        let length = text.length

        func paint(_ range: NSRange, _ color: NSColor) {
            if range.length > 0 { result.addAttribute(.foregroundColor, value: color, range: range) }
        }
        func isWordStart(_ c: unichar) -> Bool { c == 0x5F || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c > 0x7F }
        func isWordPart(_ c: unichar) -> Bool { isWordStart(c) || (c >= 0x30 && c <= 0x39) }
        func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }

        var i = 0
        while i < length {
            let c = text.character(at: i)
            let next: unichar = i + 1 < length ? text.character(at: i + 1) : 0

            // Comments: `//`, `#`, `--` (before a space) to the end of the line; `/* … */`.
            if (c == 0x2F && next == 0x2F) || c == 0x23 || (c == 0x2D && next == 0x2D) {
                let line = text.lineRange(for: NSRange(location: i, length: 0))
                var end = NSMaxRange(line)
                while end > i, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
                paint(NSRange(location: i, length: end - i), comment)
                i = end
                continue
            }
            if c == 0x2F && next == 0x2A {
                let close = text.range(of: "*/", range: NSRange(location: i + 2, length: length - i - 2))
                let end = close.location == NSNotFound ? length : NSMaxRange(close)
                paint(NSRange(location: i, length: end - i), comment)
                i = end
                continue
            }
            // Strings, to the closing quote on the same line; a backslash escapes.
            if c == 0x22 || c == 0x27 || c == 0x60 {
                var j = i + 1
                while j < length {
                    let d = text.character(at: j)
                    if d == 0x5C { j += 2; continue }
                    if d == c { j += 1; break }
                    if d == 0x0A && c != 0x60 { break }
                    j += 1
                }
                let end = min(j, length)
                paint(NSRange(location: i, length: end - i), string)
                i = end
                continue
            }
            // Numbers, not the digits inside a word.
            if isDigit(c) {
                var j = i + 1
                while j < length, isDigit(text.character(at: j)) || text.character(at: j) == 0x2E || text.character(at: j) == 0x5F { j += 1 }
                paint(NSRange(location: i, length: j - i), number)
                i = j
                continue
            }
            // Words: a keyword, or a name followed by `(` (a call).
            if isWordStart(c) {
                var j = i + 1
                while j < length, isWordPart(text.character(at: j)) { j += 1 }
                let word = text.substring(with: NSRange(location: i, length: j - i))
                if keywords.contains(word.lowercased()) {
                    paint(NSRange(location: i, length: j - i), keyword)
                } else if j < length, text.character(at: j) == 0x28 {
                    paint(NSRange(location: i, length: j - i), call)
                }
                i = j
                continue
            }
            i += 1
        }
        return result
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        func color(_ rgb: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
        let lightColor = color(light), darkColor = color(dark)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }
}
