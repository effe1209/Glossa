//
//  ColorContrast.swift
//  Glossa
//
//  WCAG contrast between two colours, and the one adjustment that uses it:
//  an underline that would not show on its page is deepened toward black. A
//  colour that already shows is left alone, and nothing here changes a stored
//  colour: it only says how to draw one.
//

import AppKit

nonisolated enum ColorContrast {
    /// WCAG 1.4.11: the least contrast for a graphic that must be seen.
    static let minimumForGraphics: Double = 3

    /// Relative luminance (WCAG 2.x) of `color` after sRGB conversion, composited over
    /// `background` when it is translucent; nil if it has no sRGB form.
    static func relativeLuminance(of color: NSColor, over background: NSColor? = nil) -> Double? {
        guard var rgb = color.usingColorSpace(.sRGB) else { return nil }
        if rgb.alphaComponent < 1, let under = background?.usingColorSpace(.sRGB) {
            let a = rgb.alphaComponent
            rgb = NSColor(srgbRed: rgb.redComponent * a + under.redComponent * (1 - a),
                          green: rgb.greenComponent * a + under.greenComponent * (1 - a),
                          blue: rgb.blueComponent * a + under.blueComponent * (1 - a), alpha: 1)
        }
        func linear(_ c: CGFloat) -> Double {
            let v = Double(c)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    /// The contrast ratio of `color` against `background`, from 1 to 21; nil if either has no sRGB form.
    static func ratio(_ color: NSColor, against background: NSColor) -> Double? {
        guard let foreground = relativeLuminance(of: color, over: background),
              let paper = relativeLuminance(of: background) else { return nil }
        let (lighter, darker) = (max(foreground, paper), min(foreground, paper))
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// `color` as an underline on `background`: unchanged if it already has
    /// `minimum` contrast, otherwise deepened once by `deepening` toward black
    /// (the reader's long-standing readability adjustment).
    static func readableUnderline(_ color: NSColor, on background: NSColor,
                                  minimum: Double = minimumForGraphics, deepening: CGFloat) -> NSColor {
        if let ratio = ratio(color, against: background), ratio >= minimum { return color }
        return color.blended(withFraction: deepening, of: .black) ?? color
    }
}
