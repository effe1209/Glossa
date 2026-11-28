//
//  SettingsManager.swift
//  PageFlow
//
//  Centralized settings state with UserDefaults persistence
//

import Foundation
import AppKit
import SwiftUI
import Observation
import os.log

/// The color scheme the Markdown editor renders in, independent of the system
/// appearance. `.system` follows the OS; `.light`/`.dark` force the whole
/// Markdown tab surface (`MarkdownTabView`: SwiftUI colorScheme + reading
/// background) and the engine editor's `NSScrollView.appearance`
/// (`NativeTextViewWrapper`). One canonical home for both mappings so the
/// AppKit and SwiftUI legs can't drift.
enum MarkdownColorScheme: String, CaseIterable {
    case system
    case light
    case dark

    /// AppKit leg: the forced appearance for the engine's scroll view
    /// (`nil` = follow the system).
    var forcedAppearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// SwiftUI leg: the forced scheme for the Markdown tab surface
    /// (`nil` = follow the system).
    var forcedColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@Observable
@MainActor
final class SettingsManager {
    static let shared = SettingsManager()
    private let logger = Logger(subsystem: "com.pageflow", category: "SettingsManager")

    // MARK: - Color Preset Model

    struct ColorPreset: Codable, Equatable, Identifiable {
        let id: UUID
        var name: String
        var hex: String
        /// A default's stable key (`glossa.…`), or `user.…` for the reader's own;
        /// nil in lists saved before palettes had keys.
        var key: String?

        init(id: UUID = UUID(), name: String, hex: String, key: String? = nil) {
            self.id = id
            self.name = name
            self.hex = hex
            self.key = key
        }

        var color: NSColor {
            get { Self.hexToColor(hex) ?? .black }
            set { hex = Self.colorToHex(newValue) }
        }

        /// A preset's colour from its hex form (EPUB highlights store the hex).
        static func color(fromHex hex: String) -> NSColor? { HexColor.color(fromHex: hex) }

        static func hex(from color: NSColor) -> String { HexColor.hex(from: color) }

        nonisolated static func colorsMatch(_ lhs: String, _ rhs: String) -> Bool { HexColor.colorsMatch(lhs, rhs) }

        private static func hexToColor(_ hex: String) -> NSColor? { HexColor.color(fromHex: hex) }

        private static func colorToHex(_ color: NSColor) -> String { HexColor.hex(from: color) }
    }

    struct ToolbarMetrics {
        let buttonSize: CGFloat
        let iconSize: CGFloat
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        let containerHeight: CGFloat
    }

    static let defaultToolbarScale = 1.0
    static let toolbarScaleRange: ClosedRange<Double> = 0.8...2.0

    static let defaultTabScale = 1.0
    static let tabScaleRange: ClosedRange<Double> = 0.8...1.6

    static func clampedTabScale(_ scale: Double) -> Double {
        min(max(scale, tabScaleRange.lowerBound), tabScaleRange.upperBound)
    }

    static func clampedToolbarScale(_ scale: Double) -> Double {
        min(max(scale, toolbarScaleRange.lowerBound), toolbarScaleRange.upperBound)
    }

    static func toolbarMetrics(for scale: Double) -> ToolbarMetrics {
        let clampedScale = CGFloat(clampedToolbarScale(scale))
        let buttonSize = DesignTokens.toolbarButtonSize * clampedScale
        let iconSize = DesignTokens.toolbarIconSize * clampedScale
        let horizontalPadding = max(DesignTokens.spacingXS, DesignTokens.spacingSM * clampedScale)
        let verticalPadding = max(2, DesignTokens.spacingXS * clampedScale)
        let containerHeight = max(
            buttonSize + (verticalPadding * 2),
            DesignTokens.collapsedToolbarSize * clampedScale
        )

        return ToolbarMetrics(
            buttonSize: buttonSize,
            iconSize: iconSize,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding,
            containerHeight: containerHeight
        )
    }

    // MARK: - Keys

    private enum Keys {
        static let highlightPresets = "settings.highlightPresets"
        static let underlinePresets = "settings.underlinePresets"
        static let commentPresets = "settings.commentPresets"
        static let customShortcuts = "settings.customShortcuts"
        static let toolbarScale = "settings.toolbarScale"
        /// Glossa's own preferences live under `glossa.*` (see docs/GLOSSA-IDENTITY-SEPARATION.md).
        /// The `settings.*` names below them were written by earlier Glossa builds: read, never written.
        static let tabScale = "glossa.tabs.scale"
        static let legacyTabScale = "settings.tabScale"
        static let topBarAlwaysVisible = "settings.topBarAlwaysVisible"
        static let floatingToolbarAlwaysVisible = "settings.floatingToolbarAlwaysVisible"
        static let pageIndicatorAlwaysVisible = "settings.pageIndicatorAlwaysVisible"
        static let compactTabs = "settings.compactTabs"
        static let toolbarMagnificationEnabled = "settings.toolbarMagnificationEnabled"
        static let showTooltips = "settings.showTooltips"
        static let showNavigationRail = "settings.showNavigationRail"
        static let navigationRailRevealsOnHover = "settings.navigationRailRevealsOnHover"
        static let markdownColorScheme = "settings.markdownColorScheme"
        static let bookTheme = "settings.bookTheme"
        static let bookFontFamily = "settings.bookFontFamily"
        static let bookFontName = "settings.bookFontName"
        static let markdownSideMargin = "settings.markdownSideMargin"
        static let markdownFontFamily = "settings.markdownFontFamily"
        static let markdownFontSize = "settings.markdownFontSize"
        static let markdownCentersZoomedOut = "settings.markdownCentersZoomedOut"
        static let markdownPageLook = "settings.markdownPageLook"
        static let markdownPageMeasure = "glossa.markdown.pageMeasure"
        static let legacyMarkdownPageMeasure = "settings.markdownPageMeasure"
        static let markdownShowsHiddenContentRow = "settings.markdownShowsHiddenContentRow"
    }

    /// The app-default Markdown editor font. PINNED to the engine's own default
    /// (`NativeTextViewWrapper.fontName` init default) — if one changes, the
    /// Settings picker's "Default" tag stops matching stored values.
    static let defaultMarkdownFontFamily = "SF Pro"
    /// The CURATED Markdown font menu — the default plus the most common
    /// English faces (sans + the two classics) and the two most common Chinese
    /// faces (sans + serif). Every family here supports ⌘B/I/U end to end: the
    /// Chinese families ship no italic faces, so ⌘I renders through the
    /// engine's synthetic-oblique fallback (`ItalicFallback.resolveFont`).
    /// Stored values outside this list reset to the default on load, so the
    /// picker can never show a dangling selection.
    static let markdownFontFamilies: [String] = [
        defaultMarkdownFontFamily,   // SF Pro — the system sans serif
        "Helvetica Neue",
        "Times New Roman",
        "PingFang SC",               // 苹方 — the system Chinese sans
        "Songti SC",                 // 宋体 — the classic Chinese serif
    ]
    static let defaultMarkdownFontSize: Double = 16
    /// The Settings stepper's range; stored values clamp to it on load.
    static let markdownFontSizeRange: ClosedRange<Double> = 10...28
    /// The side-margin slider's range (points); stored values clamp on load.
    static let markdownSideMarginRange: ClosedRange<Double> = 0...300
    /// The reading column's width in ems of the body font (Page look).
    static let markdownPageMeasureRange: ClosedRange<Double> = 40...140

    // MARK: - Default Presets

    /// The current Glossa defaults (`MarkupPalette`), as presets.
    static let defaultHighlightPresets: [ColorPreset] = presets(from: MarkupPalette.highlightDefaults)
    static let defaultUnderlinePresets: [ColorPreset] = presets(from: MarkupPalette.underlineDefaults)

    private static func presets(from palette: [PalettePreset]) -> [ColorPreset] {
        palette.map { ColorPreset(name: $0.name, hex: $0.hex, key: $0.key) }
    }

    private static func palette(from presets: [ColorPreset]) -> [PalettePreset] {
        presets.map { PalettePreset(key: $0.key ?? "user.\($0.id.uuidString)", name: $0.name, hex: $0.hex) }
    }

    /// Keeps the reader's changes to one palette as a layer over the defaults.
    private func persistLayer(of presets: [ColorPreset], kind: MarkupKind) {
        let layer = MarkupPalette.layer(from: Self.palette(from: presets), defaults: MarkupPalette.defaults(for: kind))
        paletteStore.save(layer, kind: kind)
    }

    private var paletteStore: PaletteStore { PaletteStore(defaults: defaults) }

    /// Colour lists that couldn't be read (saved by a newer version, or damaged): the
    /// defaults show instead, nothing is overwritten, and Settings says so.
    private(set) var markupPaletteIssues: [MarkupKind: PaletteStore.Issue] = [:]

    static let defaultCommentPresets: [ColorPreset] = [
        ColorPreset(name: "Gray", hex: "#80808099")  // 99 hex = 153 = 0.6 alpha
    ]

    // MARK: - Properties

    /// Internal so a test can check where this writes without writing there.
    let defaults: UserDefaults
    private var isLoading = false

    var highlightPresets: [ColorPreset] = defaultHighlightPresets {
        didSet { if !isLoading { persistLayer(of: highlightPresets, kind: .highlight) } }
    }

    var underlinePresets: [ColorPreset] = defaultUnderlinePresets {
        didSet { if !isLoading { persistLayer(of: underlinePresets, kind: .underline) } }
    }

    var commentPresets: [ColorPreset] = defaultCommentPresets {
        didSet { if !isLoading { savePresets(commentPresets, forKey: Keys.commentPresets) } }
    }

    var customShortcuts: [String: ShortcutModel] = [:] {
        didSet {
            if !isLoading { saveShortcuts() }
            NotificationCenter.default.post(name: Self.shortcutsDidChange, object: self)
        }
    }

    /// Posted when a shortcut changes, for the open editors to rebind live.
    static let shortcutsDidChange = Notification.Name("Glossa.shortcutsDidChange")

    /// A deliberate Settings save chooses one binding across the old content
    /// contexts. Bulk loads/imports keep both original values for disclosure.
    func setShortcut(_ shortcut: ShortcutModel, for actionID: String) {
        let canonical = ShortcutCatalog.canonicalID(for: actionID)
        let conflicts = ShortcutCatalog.conflictingBindings(forCombo: shortcut, excluding: canonical, saved: customShortcuts)
        var saved = customShortcuts
        // Materialize both sides before clearing either one: a PDF replacement
        // can leave the same shared action's Markdown choice intact.
        for action in ShortcutCatalog.all where conflicts.contains(where: { $0.action.id == action.id }) {
            if let legacy = ShortcutCatalog.legacyMarkdownIDs[action.id] {
                saved[action.id] = ShortcutCatalog.shortcut(for: action.id, saved: customShortcuts)
                saved[legacy] = ShortcutCatalog.shortcut(for: legacy, saved: customShortcuts)
            }
        }
        for conflict in conflicts { saved[conflict.binding.id] = ShortcutModel.none }
        saved[canonical] = shortcut
        if let legacy = ShortcutCatalog.legacyMarkdownIDs[canonical] { saved.removeValue(forKey: legacy) }
        customShortcuts = saved
    }

    func shortcutDiscrepancy(for actionID: String) -> String? {
        let canonical = ShortcutCatalog.canonicalID(for: actionID)
        guard let legacyID = ShortcutCatalog.legacyMarkdownIDs[canonical], let markdown = customShortcuts[legacyID] else { return nil }
        let pages = ShortcutCatalog.shortcut(for: canonical, saved: customShortcuts)
        guard pages != markdown else { return nil }
        return "PDF/EPUB: \(pages.displayString) · Markdown: \(markdown.displayString). Choose a shortcut to use it everywhere."
    }

    var toolbarScale = SettingsManager.defaultToolbarScale {
        didSet {
            let clampedScale = Self.clampedToolbarScale(toolbarScale)
            if toolbarScale != clampedScale {
                toolbarScale = clampedScale
                return
            }
            if !isLoading {
                defaults.set(toolbarScale, forKey: Keys.toolbarScale)
            }
        }
    }

    /// The size of the tabs in the tab strip.
    var tabScale = SettingsManager.defaultTabScale {
        didSet {
            let clamped = Self.clampedTabScale(tabScale)
            if tabScale != clamped {
                tabScale = clamped
                return
            }
            DesignTokens.tabScale = CGFloat(tabScale)
            if !isLoading { defaults.set(tabScale, forKey: Keys.tabScale) }
        }
    }

    var isTopBarAlwaysVisible = false {
        didSet {
            if !isLoading {
                defaults.set(isTopBarAlwaysVisible, forKey: Keys.topBarAlwaysVisible)
            }
        }
    }

    var isFloatingToolbarAlwaysVisible = false {
        didSet {
            if !isLoading {
                defaults.set(isFloatingToolbarAlwaysVisible, forKey: Keys.floatingToolbarAlwaysVisible)
            }
        }
    }

    var isPageIndicatorAlwaysVisible = false {
        didSet {
            if !isLoading {
                defaults.set(isPageIndicatorAlwaysVisible, forKey: Keys.pageIndicatorAlwaysVisible)
            }
        }
    }

    /// The tab strip is the Deck: the focused tab full width, the rest as
    /// slivers. Off keeps the full-width, scrolling strip. Enabled by default
    /// (opt-out).
    var isCompactTabsEnabled = true {
        didSet {
            if !isLoading {
                defaults.set(isCompactTabsEnabled, forKey: Keys.compactTabs)
            }
        }
    }

    /// Dock-style icon magnification on the floating toolbar. Enabled by default (opt-out).
    var isToolbarMagnificationEnabled = true {
        didSet {
            if !isLoading {
                defaults.set(isToolbarMagnificationEnabled, forKey: Keys.toolbarMagnificationEnabled)
            }
        }
    }

    /// Hover tooltips (native macOS help tags) on the floating toolbar buttons. Enabled by default (opt-out).
    var showTooltips = true {
        didSet {
            if !isLoading {
                defaults.set(showTooltips, forKey: Keys.showTooltips)
            }
        }
    }

    var showNavigationRail = true {
        didSet {
            if !isLoading {
                defaults.set(showNavigationRail, forKey: Keys.showNavigationRail)
            }
        }
    }

    /// Off: a rail shows whenever its document is zoomed off the fit. On: it
    /// stays hidden while reading and appears with the pointer at its edge.
    var navigationRailRevealsOnHover = false {
        didSet {
            if !isLoading {
                defaults.set(navigationRailRevealsOnHover, forKey: Keys.navigationRailRevealsOnHover)
            }
        }
    }

    /// The theme a new book opens in: the one last chosen, or set in Settings.
    var bookTheme: EPUBReaderTheme = .system {
        didSet { if !isLoading { defaults.set(bookTheme.rawValue, forKey: Keys.bookTheme) } }
    }

    /// The font a new book opens in, likewise: a preset, and an installed
    /// family chosen over it.
    var bookFontFamily: EPUBFontFamily = .system {
        didSet { if !isLoading { defaults.set(bookFontFamily.rawValue, forKey: Keys.bookFontFamily) } }
    }

    var bookFontName: String? {
        didSet { if !isLoading { defaults.set(bookFontName, forKey: Keys.bookFontName) } }
    }

    /// What a book with no settings of its own opens in.
    var newBookTypography: EPUBTypography {
        EPUBTypography(family: bookFontFamily, fontName: bookFontName, theme: bookTheme)
    }

    /// The Markdown editor's forced color scheme. `.system` follows the OS.
    var markdownColorScheme: MarkdownColorScheme = .system {
        didSet {
            if !isLoading {
                defaults.set(markdownColorScheme.rawValue, forKey: Keys.markdownColorScheme)
            }
        }
    }

    /// The Markdown editor's left/right margin in points, user-defined (replaces
    /// the old Readable-line-length toggle). Reconciled LIVE by the engine
    /// (text-container insets), so dragging the slider re-lays mounted editors.
    var markdownSideMargin = Double(DesignTokens.markdownReadingGutter) {
        didSet {
            if !isLoading {
                defaults.set(markdownSideMargin, forKey: Keys.markdownSideMargin)
            }
        }
    }

    /// The Markdown editor's body font family — one of the curated
    /// `markdownFontFamilies`. Headings/code scale off it in the engine.
    var markdownFontFamily = SettingsManager.defaultMarkdownFontFamily {
        didSet {
            if !isLoading {
                defaults.set(markdownFontFamily, forKey: Keys.markdownFontFamily)
            }
        }
    }

    /// The Markdown editor's base body size in points.
    var markdownFontSize = SettingsManager.defaultMarkdownFontSize {
        didSet {
            if !isLoading {
                defaults.set(markdownFontSize, forKey: Keys.markdownFontSize)
            }
        }
    }

    /// Whether the Markdown document centers in the window when zoomed OUT
    /// (magnification < 1), PDF-style. Off = pinned left (default). Reconciled
    /// LIVE by the engine, so the toggle re-lays mounted editors.
    var markdownCentersZoomedOut = false {
        didSet {
            if !isLoading {
                defaults.set(markdownCentersZoomedOut, forKey: Keys.markdownCentersZoomedOut)
            }
        }
    }

    /// The width of the Page look column, in ems of the body font.
    var markdownPageMeasure = Double(DesignTokens.markdownPageMeasureEm) {
        didSet {
            let clamped = min(max(markdownPageMeasure, Self.markdownPageMeasureRange.lowerBound), Self.markdownPageMeasureRange.upperBound)
            if markdownPageMeasure != clamped { markdownPageMeasure = clamped; return }
            if !isLoading { defaults.set(markdownPageMeasure, forKey: Keys.markdownPageMeasure) }
        }
    }

    /// Page look: a centered reading column (doc 18 §4.3).
    var markdownPageLook = true {
        didSet {
            if !isLoading {
                defaults.set(markdownPageLook, forKey: Keys.markdownPageLook)
            }
        }
    }

    /// Whether collapsed Markdown sections show their hidden-content summary row.
    var markdownShowsHiddenContentRow = true {
        didSet {
            if !isLoading {
                defaults.set(markdownShowsHiddenContentRow, forKey: Keys.markdownShowsHiddenContentRow)
            }
        }
    }

    // MARK: - Init

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        isLoading = true
        loadSettings()
        isLoading = false
    }

    // MARK: - Add/Remove Presets

    func addHighlightPreset() {
        let preset = MarkupPalette.makeCustomPreset(for: .highlight, existing: Self.palette(from: highlightPresets))
        highlightPresets.append(ColorPreset(name: preset.name, hex: preset.hex, key: preset.key))
    }

    func removeHighlightPreset(at index: Int) {
        guard highlightPresets.count > 1, highlightPresets.indices.contains(index) else { return }
        highlightPresets.remove(at: index)
    }

    func addUnderlinePreset() {
        let preset = MarkupPalette.makeCustomPreset(for: .underline, existing: Self.palette(from: underlinePresets))
        underlinePresets.append(ColorPreset(name: preset.name, hex: preset.hex, key: preset.key))
    }

    func removeUnderlinePreset(at index: Int) {
        guard underlinePresets.count > 1, underlinePresets.indices.contains(index) else { return }
        underlinePresets.remove(at: index)
    }

    func addCommentPreset() {
        commentPresets.append(ColorPreset(name: "New", hex: "#80808099"))
    }

    func removeCommentPreset(at index: Int) {
        guard commentPresets.count > 1, commentPresets.indices.contains(index) else { return }
        commentPresets.remove(at: index)
    }

    // MARK: - Reset

    /// Back to the current Glossa defaults: the reader's overrides, own presets and removed
    /// defaults are cleared. What is replaced is kept (`glossa.markup.layer.*.backup`, and
    /// `glossa.markup.comment.backup` for the comment colours); `restoreColorBackup()` puts it back.
    /// Documents' annotations are not touched.
    func resetColors() {
        for kind in MarkupKind.allCases { paletteStore.resetBackingUp(kind) }
        if let comments = defaults.data(forKey: Keys.commentPresets) { defaults.set(comments, forKey: Self.commentBackupKey) }
        highlightPresets = Self.defaultHighlightPresets
        underlinePresets = Self.defaultUnderlinePresets
        commentPresets = Self.defaultCommentPresets
    }

    private static let commentBackupKey = "glossa.markup.comment.backup"

    /// The internal way back from `resetColors()`: restores the colours it replaced. Not offered
    /// in the interface. False if there was nothing to restore.
    @discardableResult
    func restoreColorBackup() -> Bool {
        let store = paletteStore
        var restored = false
        for kind in MarkupKind.allCases where store.restoreBackup(kind) { restored = true }
        isLoading = true
        highlightPresets = Self.presets(from: store.effective(.highlight))
        underlinePresets = Self.presets(from: store.effective(.underline))
        if let data = defaults.data(forKey: Self.commentBackupKey),
           let comments = try? JSONDecoder().decode([ColorPreset].self, from: data) {
            commentPresets = comments
            defaults.set(data, forKey: Keys.commentPresets)
            restored = true
        }
        isLoading = false
        return restored
    }

    func resetShortcuts() {
        customShortcuts = [:]
    }

    func resetTabScale() {
        tabScale = Self.defaultTabScale
    }

    func resetToolbarScale() {
        toolbarScale = Self.defaultToolbarScale
    }

    // MARK: - Persistence

    private func loadSettings() {
        // Highlight and underline colours: the defaults with the reader's layer
        // on top. An older install's lists are brought across once, and left as they are.
        let palettes = paletteStore
        highlightPresets = Self.presets(from: palettes.effective(.highlight))
        underlinePresets = Self.presets(from: palettes.effective(.underline))
        var issues: [MarkupKind: PaletteStore.Issue] = [:]
        for kind in MarkupKind.allCases {
            guard let issue = palettes.issue(kind) else { continue }
            issues[kind] = issue
            logger.error("Saved \(kind.rawValue) colors can't be used (\(String(describing: issue))); showing the defaults and leaving the saved data alone")
        }
        markupPaletteIssues = issues

        if let data = defaults.data(forKey: Keys.commentPresets) {
            do {
                commentPresets = try JSONDecoder().decode([ColorPreset].self, from: data)
            } catch {
                logger.error("Failed to decode comment presets: \(error.localizedDescription)")
            }
        }

        if let data = defaults.data(forKey: Keys.customShortcuts) {
            do {
                customShortcuts = try JSONDecoder().decode([String: ShortcutModel].self, from: data)
            } catch {
                logger.error("Failed to decode custom shortcuts: \(error.localizedDescription)")
            }
        }

        // The Glossa key wins; an earlier build's `settings.tabScale` is read once as a fallback.
        if let key = [Keys.tabScale, Keys.legacyTabScale].first(where: { defaults.object(forKey: $0) != nil }) {
            tabScale = Self.clampedTabScale(defaults.double(forKey: key))
        }

        if defaults.object(forKey: Keys.toolbarScale) != nil {
            toolbarScale = Self.clampedToolbarScale(defaults.double(forKey: Keys.toolbarScale))
        }

        isTopBarAlwaysVisible = defaults.bool(forKey: Keys.topBarAlwaysVisible)
        isFloatingToolbarAlwaysVisible = defaults.bool(forKey: Keys.floatingToolbarAlwaysVisible)
        isPageIndicatorAlwaysVisible = defaults.bool(forKey: Keys.pageIndicatorAlwaysVisible)
        isCompactTabsEnabled = defaults.object(forKey: Keys.compactTabs) == nil ? true : defaults.bool(forKey: Keys.compactTabs)

        // Opt-out default: only override the `true` default when a value was explicitly stored.
        if defaults.object(forKey: Keys.toolbarMagnificationEnabled) != nil {
            isToolbarMagnificationEnabled = defaults.bool(forKey: Keys.toolbarMagnificationEnabled)
        }

        if defaults.object(forKey: Keys.showTooltips) != nil {
            showTooltips = defaults.bool(forKey: Keys.showTooltips)
        }

        if defaults.object(forKey: Keys.showNavigationRail) != nil {
            showNavigationRail = defaults.bool(forKey: Keys.showNavigationRail)
        }
        navigationRailRevealsOnHover = defaults.bool(forKey: Keys.navigationRailRevealsOnHover)

        if let raw = defaults.string(forKey: Keys.bookTheme), let theme = EPUBReaderTheme(rawValue: raw) {
            bookTheme = theme
        }
        if let raw = defaults.string(forKey: Keys.bookFontFamily), let family = EPUBFontFamily(rawValue: raw) {
            bookFontFamily = family
        }
        bookFontName = defaults.string(forKey: Keys.bookFontName)
        if let raw = defaults.string(forKey: Keys.markdownColorScheme),
           let scheme = MarkdownColorScheme(rawValue: raw) {
            markdownColorScheme = scheme
        }

        if defaults.object(forKey: Keys.markdownSideMargin) != nil {
            markdownSideMargin = min(
                max(defaults.double(forKey: Keys.markdownSideMargin), Self.markdownSideMarginRange.lowerBound),
                Self.markdownSideMarginRange.upperBound
            )
        }

        // Validate against the curated list, not just non-emptiness: fonts we
        // no longer offer (or that were uninstalled) reset to the default so
        // the Settings picker never shows a dangling selection.
        if let family = defaults.string(forKey: Keys.markdownFontFamily),
           Self.markdownFontFamilies.contains(family) {
            markdownFontFamily = family
        }
        let storedSize = defaults.double(forKey: Keys.markdownFontSize)
        if storedSize > 0 {
            // Clamp on load, not just in the Stepper (house precedent: clampedToolbarScale).
            markdownFontSize = min(
                max(storedSize, Self.markdownFontSizeRange.lowerBound),
                Self.markdownFontSizeRange.upperBound
            )
        }

        markdownCentersZoomedOut = defaults.bool(forKey: Keys.markdownCentersZoomedOut)
        if let key = [Keys.markdownPageMeasure, Keys.legacyMarkdownPageMeasure].first(where: { defaults.object(forKey: $0) != nil }) {
            markdownPageMeasure = defaults.double(forKey: key)
        }
        markdownPageLook = defaults.object(forKey: Keys.markdownPageLook) == nil ? true : defaults.bool(forKey: Keys.markdownPageLook)
        if defaults.object(forKey: Keys.markdownShowsHiddenContentRow) != nil {
            markdownShowsHiddenContentRow = defaults.bool(forKey: Keys.markdownShowsHiddenContentRow)
        }
    }

    private func savePresets(_ presets: [ColorPreset], forKey key: String) {
        do {
            let data = try JSONEncoder().encode(presets)
            defaults.set(data, forKey: key)
        } catch {
            logger.error("Failed to encode presets for \(key): \(error.localizedDescription)")
        }
    }

    private func saveShortcuts() {
        do {
            let data = try JSONEncoder().encode(customShortcuts)
            defaults.set(data, forKey: Keys.customShortcuts)
        } catch {
            logger.error("Failed to encode shortcuts: \(error.localizedDescription)")
        }
    }
}
