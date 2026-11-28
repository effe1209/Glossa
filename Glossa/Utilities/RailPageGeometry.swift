//
//  RailPageGeometry.swift
//  Glossa
//
//  What the PDF navigation rail needs to know about where the pages are, kept
//  independent of how far the reader has scrolled.
//

import CoreGraphics

/// The rail keeps its marks off the paper, which only takes the pages' sideways
/// extent. Their vertical position changes on every scroll tick, and publishing
/// it made the observed state change that often: each tick invalidated the whole
/// tab view while the reader was mid-gesture. Reduced to columns, the geometry
/// only changes when the layout does (zoom, window width, display mode).
enum RailPageGeometry {
    /// Where two edges can differ and still be the same edge: sub-point jitter
    /// from PDFKit's layout rounding is not a layout change.
    static let tolerance: CGFloat = 0.5

    /// The visible pages as columns: one rect per run of pages sharing horizontal
    /// space, spanning the viewport's full height. Pages stacked above one another
    /// (continuous scrolling) become a single column however many are visible.
    static func columns(of pageRects: [CGRect], in viewport: CGRect) -> [CGRect] {
        guard !viewport.isEmpty else { return [] }
        let spans = pageRects.filter { !$0.isEmpty }.map { ($0.minX, $0.maxX) }.sorted { $0.0 < $1.0 }
        var merged: [(CGFloat, CGFloat)] = []
        for span in spans {
            if let last = merged.last, span.0 <= last.1 + tolerance {
                merged[merged.count - 1].1 = max(last.1, span.1)
            } else {
                merged.append(span)
            }
        }
        return merged.map { CGRect(x: $0.0, y: viewport.minY, width: $0.1 - $0.0, height: viewport.height) }
    }

    /// Whether two sets of columns are the same layout, to within `tolerance`.
    static func sameLayout(_ lhs: [CGRect], _ rhs: [CGRect]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            abs(a.minX - b.minX) <= tolerance && abs(a.maxX - b.maxX) <= tolerance
                && abs(a.minY - b.minY) <= tolerance && abs(a.maxY - b.maxY) <= tolerance
        }
    }
}
