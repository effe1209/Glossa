//
//  TabWidthLayout.swift
//  Glossa
//
//  The pure decision of how wide each tab is in the full-width strip: all
//  tabs share one width that starts at the preferred width, shrinks as tabs
//  are added, stops at the minimum (the strip scrolls from there) and grows
//  back as tabs close or the window widens.
//

import CoreGraphics

struct TabWidthLayout: Equatable {
    /// Every tab's width, in whole points so the strip doesn't shimmer while
    /// the window resizes.
    let tabWidth: CGFloat
    /// The minimum width still doesn't fit: the strip scrolls.
    let scrolls: Bool

    /// - Parameters:
    ///   - count: Number of tabs.
    ///   - availableWidth: Width the tabs may fill (strip minus its padding
    ///     and the new-tab button). Zero or less means "not measured yet".
    init(
        count: Int,
        availableWidth: CGFloat,
        spacing: CGFloat = DesignTokens.tabSpacing,
        preferredWidth: CGFloat = DesignTokens.tabAdaptivePreferredWidth,
        minWidth: CGFloat = DesignTokens.tabAdaptiveMinWidth,
        maxWidth: CGFloat = DesignTokens.tabAdaptiveMaxWidth
    ) {
        let upper = min(max(preferredWidth, minWidth), max(maxWidth, minWidth))
        guard count > 0, availableWidth > 0 else {
            tabWidth = upper
            scrolls = false
            return
        }
        let gaps = CGFloat(count - 1) * spacing
        let fitting = ((availableWidth - gaps) / CGFloat(count)).rounded(.down)
        tabWidth = min(max(fitting, minWidth), upper)
        scrolls = CGFloat(count) * minWidth + gaps > availableWidth
    }

    /// The width `count` tabs need at the minimum width. This, not the
    /// current width, is what the top chrome compares against when deciding
    /// whether the toolbar fits beside the tabs: it doesn't depend on the
    /// strip's own width, so folding the toolbar can't resize the tabs back
    /// into the decision that folded it.
    static func minimumContentWidth(
        count: Int,
        spacing: CGFloat = DesignTokens.tabSpacing,
        minWidth: CGFloat = DesignTokens.tabAdaptiveMinWidth
    ) -> CGFloat {
        guard count > 0 else { return 0 }
        return CGFloat(count) * minWidth + CGFloat(count - 1) * spacing
    }
}
