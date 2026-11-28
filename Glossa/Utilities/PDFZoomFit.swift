//
//  PDFZoomFit.swift
//  PageFlow
//
//  Pure fit-to-view scale calculation for PDF pages: Fit Page and Fit Width,
//  measured on a page's real on-screen size.
//

import CoreGraphics
import PDFKit

/// The single source of the PDF fit formulas. It depends only on its inputs,
/// never on a live `PDFView`, so every branch is unit-testable.
///
/// A page's size here is its *effective* size: the box PDFKit actually draws
/// (the view's display box, not always the media box) with the page's rotation
/// applied, so a landscape slide and a portrait A4 fit by their own shapes and
/// a page rotated a quarter turn swaps its width and height.
enum PDFZoomFit {
    /// What a fit makes visible.
    enum Mode: Equatable, Sendable {
        /// The whole page, both dimensions.
        case page
        /// The page's full width; the height scrolls.
        case width

        /// The fit a display mode implies when the reader hasn't chosen one:
        /// stacked pages fit their width, a single page or spread fits whole.
        static func implied(by displayMode: PDFDisplayMode) -> Mode {
            switch displayMode {
            case .singlePageContinuous, .twoUpContinuous: .width
            case .singlePage, .twoUp: .page
            @unknown default: .width
            }
        }
    }

    /// The view and layout a fit is measured against.
    struct Layout: Equatable, Sendable {
        var viewportSize: CGSize
        var displayMode: PDFDisplayMode
        /// Space kept clear on each axis in total (both sides together).
        var padding: CGFloat
        /// Space between the two pages of a spread.
        var twoPageGap: CGFloat

        var isTwoUp: Bool { displayMode == .twoUp || displayMode == .twoUpContinuous }
    }

    /// The size a page occupies on screen at a scale of 1: its box, turned by its rotation.
    static func effectiveSize(boxSize: CGSize, rotation: Int) -> CGSize {
        let quarterTurn = ((rotation % 180) + 180) % 180 == 90
        return quarterTurn ? CGSize(width: boxSize.height, height: boxSize.width) : boxSize
    }

    /// The scale that fits `pageSize` (an effective size) to `layout` in `mode`,
    /// or nil while the geometry isn't usable yet (a view still laying out).
    /// The result isn't clamped to the zoom range: `clamped(_:)` does that.
    static func scale(mode: Mode, pageSize: CGSize, layout: Layout) -> CGFloat? {
        let width = layout.viewportSize.width - layout.padding
        let height = layout.viewportSize.height - layout.padding
        guard width > 0, height > 0, pageSize.width > 0, pageSize.height > 0 else { return nil }

        let contentWidth = layout.isTwoUp ? pageSize.width * 2 + layout.twoPageGap : pageSize.width
        let widthScale = width / contentWidth
        switch mode {
        case .width: return widthScale
        case .page: return min(widthScale, height / pageSize.height)
        }
    }

    /// `scale` held to the range the view can show.
    static func clamped(_ scale: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        min(max(scale, minimum), maximum)
    }

    /// A scale as the percentage readers know it ("125%").
    static func percentage(of scale: CGFloat) -> Int {
        guard scale.isFinite, scale > 0 else { return 0 }
        return Int((scale * 100).rounded())
    }
}
