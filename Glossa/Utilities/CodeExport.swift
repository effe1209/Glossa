//
//  CodeExport.swift
//  PageFlow
//
//  Colours a code block for export: the editor's own highlighter, read out as HTML
//  spans in its light-mode colours, so an exported block looks as the note's does.
//

import AppKit
import MarkdownEngineCodeBlocks

@MainActor
enum CodeExport {
    private static let highlighter = HighlighterSwiftBridge()

    /// `code` as HTML (escaped, with a span per coloured run), or nil when it has no colours.
    static func html(code: String, language: String) -> String? {
        let name = language.split(separator: " ").first.map(String.init)
        guard let coloured = highlighter.highlight(code: code, language: name), coloured.length == (code as NSString).length else {
            return nil
        }
        var html = ""
        let text = code as NSString
        coloured.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: coloured.length)) { value, range, _ in
            let piece = MarkdownHTML.escape(text.substring(with: range))
            if let hex = lightHex(of: value as? NSColor) {
                html += "<span style=\"color: \(hex)\">\(piece)</span>"
            } else {
                html += piece
            }
        }
        return html
    }

    /// The colour as it reads on a white page, whatever the system's appearance is now.
    private static func lightHex(of color: NSColor?) -> String? {
        guard let color else { return nil }
        var hex: String?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                         Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        }
        return hex
    }
}
