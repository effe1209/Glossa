//
//  MathExport.swift
//  PageFlow
//
//  Typesets a note's formulas for export. `$…$` and `$$…$$` are drawn with SwiftMath, the
//  same typesetter the app shows them with, and placed in the PDF and HTML as
//  embedded images, so the exported PDF and HTML show the formula and not its source.
//

import AppKit
import SwiftMath

@MainActor
enum MathExport {
    /// How sharp the pictures are: drawn this many times larger than they are shown.
    private static let resolution: CGFloat = 4
    /// A display formula is set larger than the text around it.
    private static let displayScale: CGFloat = 1.3
    /// Inline formulas are set a little larger than the text: SwiftMath's text style reads small beside a sans-serif body.
    private static let inlineScale: CGFloat = 1.2
    private static let defaultFontSize: CGFloat = 15

    // MARK: HTML export

    /// The formula as an image embedded in the HTML, with its source as the alternative text.
    static func embedded(latex: String, isDisplay: Bool) -> String {
        // The preview asks again on every pause in typing: a formula already drawn is kept.
        let key = (isDisplay ? "D" : "I") + latex
        if let cached = cache.object(forKey: key as NSString) { return cached as String }
        let html = render(latex: latex, isDisplay: isDisplay)
        cache.setObject(html as NSString, forKey: key as NSString, cost: html.utf16.count)
        return html
    }

    private static let cache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.totalCostLimit = 20_000_000
        return cache
    }()

    private static func render(latex: String, isDisplay: Bool) -> String {
        guard let image = image(latex: latex, fontSize: defaultFontSize * (isDisplay ? displayScale : inlineScale), isDisplay: isDisplay),
              let png = pngData(of: image) else {
            return MarkdownHTML.escape(isDisplay ? "$$\(latex)$$" : "$\(latex)$")
        }
        // In em of the page's 16 px root, so the picture grows and shrinks with the text around it.
        let em = { (points: CGFloat) in String(format: "%.3f", points / 16) }
        return "<img alt=\"\(MarkdownHTML.escape(latex))\" style=\"vertical-align: middle; width: \(em(image.size.width))em; "
            + "height: \(em(image.size.height))em\" src=\"data:image/png;base64,\(png.base64EncodedString())\">"
    }

    // MARK: Drawing

    /// The formula drawn at `fontSize`, as an image `resolution` times sharper than its size in points.
    /// Nil when it can't be read (an unknown command, unbalanced braces).
    static func image(latex: String, fontSize: CGFloat, isDisplay: Bool) -> NSImage? {
        let source = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return nil }
        let renderer = MTMathImage(latex: source, fontSize: fontSize, textColor: .black,
                                   labelMode: isDisplay ? .display : .text, textAlignment: .center)
        renderer.contentInsets = MTEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
        let (error, drawn) = renderer.asImage()
        guard error == nil, let drawn, drawn.size.width > 0, drawn.size.height > 0 else { return nil }

        let pointSize = drawn.size
        let pixels = NSSize(width: ceil(pointSize.width * resolution), height: ceil(pointSize.height * resolution))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawn.draw(in: NSRect(origin: .zero, size: pixels), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = pointSize          // sharper than its size says
        let result = NSImage(size: pointSize)
        result.addRepresentation(bitmap)
        return result
    }

    private static func pngData(of image: NSImage) -> Data? {
        guard let bitmap = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
