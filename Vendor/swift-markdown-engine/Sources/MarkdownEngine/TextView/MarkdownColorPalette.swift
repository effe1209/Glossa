//
//  MarkdownColorPalette.swift
//  MarkdownEngine
//
//  The colours a writer can give text, or put behind it. Each is written into the note
//  as plain HTML, which other Markdown readers (GitHub, Obsidian) also understand:
//
//      <span style="color: #E03E3E">red text</span>
//      <mark style="background: #FFE066">highlighted text</mark>
//

import AppKit

/// What a colour is applied to.
public enum MarkdownColorKind: Sendable {
    /// The text's own colour.
    case text
    /// The colour behind the text.
    case highlight
}

public enum MarkdownColorPalette {
    public struct Swatch: Sendable, Equatable {
        public let name: String
        /// `#RRGGBB`.
        public let hex: String
        public var color: NSColor { Self.color(fromHex: hex) ?? .gray }

        static func color(fromHex hex: String) -> NSColor? {
            var digits = hex
            if digits.hasPrefix("#") { digits.removeFirst() }
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }

    /// Text colours: strong enough to read on white and, as they are, on dark.
    public static let text: [Swatch] = [
        Swatch(name: "Red", hex: "#E03E3E"), Swatch(name: "Orange", hex: "#E8710A"), Swatch(name: "Yellow", hex: "#CB912F"),
        Swatch(name: "Green", hex: "#0F9D58"), Swatch(name: "Blue", hex: "#2F80ED"), Swatch(name: "Purple", hex: "#8E44EC"),
        Swatch(name: "Pink", hex: "#D6336C"), Swatch(name: "Gray", hex: "#787774"),
    ]

    /// Highlight colours: bright markers, light enough for black text to stay readable on them.
    public static let highlight: [Swatch] = [
        Swatch(name: "Yellow", hex: "#FFE066"), Swatch(name: "Green", hex: "#A7F3D0"), Swatch(name: "Blue", hex: "#BAE6FD"),
        Swatch(name: "Pink", hex: "#FBCFE8"), Swatch(name: "Orange", hex: "#FED7AA"), Swatch(name: "Purple", hex: "#DDD6FE"),
        Swatch(name: "Red", hex: "#FECACA"), Swatch(name: "Gray", hex: "#E5E7EB"),
    ]

    public static func swatches(for kind: MarkdownColorKind) -> [Swatch] { kind == .text ? text : highlight }
}
