//
//  MarkdownEditorTheme.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Color palette for the Markdown editor engine.
//
//  All user-visible colors used by the engine are routed through this
//  struct. Defaults map to system colors so the editor adapts to light/
//  dark mode automatically. Embedders that want a custom palette (for
//  example, a sepia or high-contrast preset) can replace any subset of
//  the colors without touching engine source files.
//

import AppKit
import Foundation

// MARK: - Theme

/// Color palette consumed by the Markdown editor engine.
///
/// Every color the engine puts on screen is read from this struct, so a
/// single override is enough to retheme the entire editor. The defaults
/// reproduce a system-native macOS look using `NSColor` dynamic system
/// colors, so light/dark-mode switching keeps working without extra code.
public struct MarkdownEditorTheme: Sendable, Equatable {

    // MARK: Text colors

    /// Foreground color for plain body text and the typing caret.
    public var bodyText: NSColor
    /// Foreground color for de-emphasized text and most syntax markers.
    /// Defaults to `secondaryLabelColor` so it tracks the system style.
    public var mutedText: NSColor
    /// Foreground color for content the engine wants to deemphasize further
    /// than `mutedText` — for example, broken wiki-links.
    public var disabledText: NSColor
    /// Foreground color for heading marker glyphs (`#`, `##`, …).
    public var headingMarker: NSColor

    // MARK: Links

    /// Foreground color for hyperlinks that resolve to an URL.
    public var link: NSColor
    /// Foreground color for incomplete `[text]` patterns (no URL yet).
    public var incompleteLink: NSColor

    // MARK: Find / search highlights

    /// Background color used to highlight all matches when the user is
    /// running an in-document search.
    ///
    /// The default is `.systemYellow` so embedders that don't customize
    /// this still get a sensible result. Apps with their own brand color
    /// (for example, the Nodes app uses its custom yellow) should override
    /// this to match their palette.
    public var findMatchHighlight: NSColor
    /// Background color used to highlight the currently-focused match
    /// during in-document search. Typically a stronger version of
    /// ``findMatchHighlight``.
    public var findCurrentMatchHighlight: NSColor

    // MARK: LaTeX rendering

    /// Foreground color used when rendering LaTeX formulas in light mode.
    public var latexLightModeText: NSColor
    /// Foreground color used when rendering LaTeX formulas in dark mode.
    public var latexDarkModeText: NSColor

    // MARK: Strikethrough / decoration

    /// Stroke color used for strikethrough decorations
    /// (e.g. completed task list items, horizontal rules).
    public var strikethroughColor: NSColor

    // MARK: Tables (the reference editor, doc 24 §5.10)

    /// The header row's fill: #f5f3ed on light; on dark a white wash that is
    /// the reference editor's #151515 over its #0b0b0b page.
    public var tableHeaderFill: NSColor
    /// Header cell text, regular weight: #52514e on light, #c3c2b7 on dark.
    public var tableHeaderText: NSColor
    /// The 1 pt cell grid: #e8e5dc on light, white at 10 % on dark.
    public var tableBorder: NSColor
    /// Behind `==highlighted==` text: the reference editor's #fab219 at 33 % (#fde6b3 light, #5a4210 dark).
    public var highlight: NSColor = MarkdownEditorTheme.referenceHighlight

    // MARK: Quotes, callouts and code

    /// The bar beside a `>` quote: a vivid blue, so a quote reads at a glance.
    public var quoteBar: NSColor = MarkdownEditorTheme.referenceQuoteBar
    /// A quote's text: darker than muted text, so it stays easy to read beside the bar.
    public var quoteText: NSColor = NSColor.labelColor.withAlphaComponent(0.78)
    /// Text of an `inline code` span: a vivid red.
    public var inlineCodeText: NSColor = MarkdownEditorTheme.referenceInlineCode

    // MARK: Init

    public init(
        bodyText: NSColor = .labelColor,
        mutedText: NSColor = .secondaryLabelColor,
        disabledText: NSColor = .tertiaryLabelColor,
        headingMarker: NSColor = .gray,
        link: NSColor = .linkColor,
        incompleteLink: NSColor = .systemBlue,
        findMatchHighlight: NSColor = .systemYellow,
        findCurrentMatchHighlight: NSColor = .systemYellow,
        latexLightModeText: NSColor = .black,
        latexDarkModeText: NSColor = .white,
        strikethroughColor: NSColor = .labelColor,
        tableHeaderFill: NSColor = MarkdownEditorTheme.referenceTableHeaderFill,
        tableHeaderText: NSColor = MarkdownEditorTheme.referenceTableHeaderText,
        tableBorder: NSColor = MarkdownEditorTheme.referenceTableBorder
    ) {
        self.bodyText = bodyText
        self.mutedText = mutedText
        self.disabledText = disabledText
        self.headingMarker = headingMarker
        self.link = link
        self.incompleteLink = incompleteLink
        self.findMatchHighlight = findMatchHighlight
        self.findCurrentMatchHighlight = findCurrentMatchHighlight
        self.latexLightModeText = latexLightModeText
        self.latexDarkModeText = latexDarkModeText
        self.strikethroughColor = strikethroughColor
        self.tableHeaderFill = tableHeaderFill
        self.tableHeaderText = tableHeaderText
        self.tableBorder = tableBorder
    }

    // Shared instances: dynamic colors compare by identity, and themes built
    // with the defaults must stay equal.
    public static let referenceTableHeaderFill = reference(light: 0xF5F3ED, dark: (0xFFFFFF, 0.04))
    public static let referenceTableHeaderText = reference(light: 0x52514E, dark: (0xC3C2B7, 1))
    public static let referenceTableBorder = reference(light: 0xE8E5DC, dark: (0xFFFFFF, 0.10))
    public static let referenceHighlight = reference(light: 0xFDE6B3, dark: (0x5A4210, 1))
    public static let referenceQuoteBar = reference(light: 0x2F80ED, dark: (0x5AA0FF, 1))
    public static let referenceInlineCode = reference(light: 0xE5173F, dark: (0xFF6B7D, 1))

    /// The colour of an Obsidian callout (`> [!note]`) of the given kind: its bar and its title.
    /// Kinds that share a look (`warning`, `caution`) share the one colour object.
    public static func calloutColor(for kind: String) -> NSColor {
        let group: String
        switch kind.lowercased() {
        case "info", "abstract", "summary", "tldr", "todo": group = "info"
        case "tip", "hint", "important": group = "tip"
        case "success", "check", "done": group = "success"
        case "question", "help", "faq": group = "question"
        case "warning", "caution", "attention": group = "warning"
        case "failure", "fail", "missing", "danger", "error", "bug": group = "danger"
        case "example": group = "example"
        case "quote", "cite": group = "quote"
        default: group = "note"   // note, and any kind not listed
        }
        return calloutColors[group] ?? calloutColors["note"]!
    }

    private static let calloutColors: [String: NSColor] = [
        "note": reference(light: 0x2F80ED, dark: (0x5AA0FF, 1)),
        "info": reference(light: 0x00A0B8, dark: (0x2BC4DB, 1)),
        "tip": reference(light: 0x00A58C, dark: (0x2BD1B3, 1)),
        "success": reference(light: 0x08A845, dark: (0x3DD068, 1)),
        "question": reference(light: 0xD9A400, dark: (0xF2C230, 1)),
        "warning": reference(light: 0xE8710A, dark: (0xFF9F43, 1)),
        "danger": reference(light: 0xE93147, dark: (0xFF6B7D, 1)),
        "example": reference(light: 0x7852EE, dark: (0xA48BFF, 1)),
        "quote": reference(light: 0x7A7A7A, dark: (0xA8A8A8, 1)),
    ]

    /// A dynamic color: an opaque sRGB `light` value, and a `dark` value with alpha.
    public static func reference(light: UInt32, dark: (rgb: UInt32, alpha: CGFloat)) -> NSColor {
        func color(_ rgb: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
        }
        let lightColor = color(light, 1)
        let darkColor = color(dark.rgb, dark.alpha)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    /// System-native palette built from `NSColor` dynamic system colors.
    ///
    /// Use this if you want the engine to look like a stock macOS
    /// `NSTextView`. It's also the default when no theme is supplied.
    public static let `default` = MarkdownEditorTheme()
}
