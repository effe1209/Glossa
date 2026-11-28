//
//  MarkupPalette.swift
//  Glossa
//
//  The colours offered for highlights and underlines, and how a reader's
//  changes to them are kept.
//
//  The defaults live in code, each with a stable key. What is saved is only
//  the reader's own layer on top: presets they added, defaults they changed or
//  removed, and the order. So a later release can change the defaults without
//  touching anyone's customisations, and "reset" is simply an empty layer.
//
//  Pure Foundation and AppKit: no settings object, no views, so it is testable
//  on its own. Storage is injected as a `UserDefaults`.
//

import AppKit

nonisolated enum MarkupKind: String, CaseIterable, Sendable {
    case highlight, underline
}

/// One colour in a palette. `key` is stable: `glossa.…` for a default, `user.…` for the reader's own.
nonisolated struct PalettePreset: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var hex: String
}

/// What the reader changed from the defaults of one palette.
nonisolated struct PaletteLayer: Codable, Equatable, Sendable {
    static let currentSchema = 1

    struct Override: Codable, Equatable, Sendable {
        var name: String?
        var hex: String?
    }

    var schema: Int = PaletteLayer.currentSchema
    /// The reader's own presets.
    var custom: [PalettePreset] = []
    /// Name or colour changed on a default, by its key.
    var overrides: [String: Override] = [:]
    /// Defaults the reader explicitly removed, by key.
    var hiddenDefaults: [String] = []
    /// The order shown, by key; empty when it is the natural one.
    var order: [String] = []

    static let empty = PaletteLayer()
    var isEmpty: Bool { custom.isEmpty && overrides.isEmpty && hiddenDefaults.isEmpty && order.isEmpty }
}

// MARK: - Palettes

nonisolated enum MarkupPalette {
    /// The official Glossa highlight palette.
    static let highlightDefaults: [PalettePreset] = [
        PalettePreset(key: "glossa.highlight.yellow", name: "Yellow", hex: "#FFF0A8"),
        PalettePreset(key: "glossa.highlight.green", name: "Green", hex: "#C8E3CC"),
        PalettePreset(key: "glossa.highlight.blue", name: "Blue", hex: "#C9DFF2"),
        PalettePreset(key: "glossa.highlight.pink", name: "Pink", hex: "#F2CED5")
    ]

    /// The underline companions: the same families, deep enough (3:1 or more
    /// on white) to show as a line. Distinct from the highlight colours.
    static let underlineDefaults: [PalettePreset] = [
        PalettePreset(key: "glossa.underline.yellow", name: "Yellow", hex: "#B8860B"),
        PalettePreset(key: "glossa.underline.green", name: "Green", hex: "#4F9A63"),
        PalettePreset(key: "glossa.underline.blue", name: "Blue", hex: "#3F83C0"),
        PalettePreset(key: "glossa.underline.pink", name: "Pink", hex: "#D2607C")
    ]

    static func defaults(for kind: MarkupKind) -> [PalettePreset] {
        kind == .highlight ? highlightDefaults : underlineDefaults
    }

    /// What a new highlight or underline uses when the preset list gives nothing.
    static var defaultHighlightHex: String { highlightDefaults[0].hex }
    static var defaultUnderlineHex: String { underlineDefaults[0].hex }
    static var defaultHighlightColor: NSColor { HexColor.color(fromHex: defaultHighlightHex) ?? .systemYellow }
    static var defaultUnderlineColor: NSColor { HexColor.color(fromHex: defaultUnderlineHex) ?? .systemYellow }

    /// The colour a new preset starts as: the first default not already in the list.
    static func newPresetHex(for kind: MarkupKind, existing: [PalettePreset]) -> String {
        let all = defaults(for: kind)
        return all.first { candidate in !existing.contains { HexColor.colorsMatch($0.hex, candidate.hex) } }?.hex ?? all[0].hex
    }

    /// A preset the reader adds: the first default colour not already in the list (the first
    /// default if all are), named "New", with a fresh stable key (`user.<UUID>`).
    static func makeCustomPreset(for kind: MarkupKind, existing: [PalettePreset], name: String = "New") -> PalettePreset {
        PalettePreset(key: "user.\(UUID().uuidString)", name: name, hex: newPresetHex(for: kind, existing: existing))
    }

    // MARK: Resolving

    /// The list the reader sees: the defaults with their layer applied. Never empty.
    static func resolve(defaults: [PalettePreset], layer: PaletteLayer) -> [PalettePreset] {
        var list: [PalettePreset] = defaults
            .filter { !layer.hiddenDefaults.contains($0.key) }
            .map { preset in
                guard let change = layer.overrides[preset.key] else { return preset }
                return PalettePreset(key: preset.key, name: change.name ?? preset.name, hex: change.hex ?? preset.hex)
            }
        list += layer.custom
        if !layer.order.isEmpty {
            // Listed keys in their order; keys the layer doesn't know (a default added later) follow.
            let position = Dictionary(layer.order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let known = list.filter { position[$0.key] != nil }.sorted { position[$0.key]! < position[$1.key]! }
            list = known + list.filter { position[$0.key] == nil }
        }
        return list.isEmpty ? defaults : list
    }

    /// The layer that makes `defaults` look like `effective`; empty when they already do.
    static func layer(from effective: [PalettePreset], defaults: [PalettePreset]) -> PaletteLayer {
        let defaultsByKey = Dictionary(defaults.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var layer = PaletteLayer()
        for preset in effective {
            guard let base = defaultsByKey[preset.key] else { layer.custom.append(preset); continue }
            var change = PaletteLayer.Override()
            if preset.name != base.name { change.name = preset.name }
            if !HexColor.colorsMatch(preset.hex, base.hex) { change.hex = preset.hex }
            if change != PaletteLayer.Override() { layer.overrides[preset.key] = change }
        }
        let shown = Set(effective.map(\.key))
        layer.hiddenDefaults = defaults.map(\.key).filter { !shown.contains($0) }
        // Order is saved only when the reader reordered: otherwise it is the natural one, the
        // defaults first and then their own presets, and a default added by a later release
        // joins the defaults. A reordered list is kept, and a new default is appended to it.
        let natural = defaults.map(\.key).filter { !layer.hiddenDefaults.contains($0) } + layer.custom.map(\.key)
        let order = effective.map(\.key)
        layer.order = order == natural ? [] : order
        return layer
    }
}

// MARK: - Hex colours

/// `#RRGGBB` / `#RRGGBBAA` text and colours, as presets and stored highlights keep them.
nonisolated enum HexColor {
    static func rgba(_ hex: String) -> UInt32? {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? trimmed.dropFirst() : trimmed[...]
        guard digits.count == 6 || digits.count == 8, digits.allSatisfy(\.isHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        return digits.count == 6 ? (value << 8) | 0xFF : value
    }

    static func color(fromHex hex: String) -> NSColor? {
        guard let rgba = rgba(hex) else { return nil }
        return NSColor(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
                       blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
    }

    static func hex(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000FF" }
        return String(format: "#%02X%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255), Int(rgb.alphaComponent * 255))
    }

    /// The same colour, whether or not one side spells out an opaque alpha.
    static func colorsMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        guard let left = rgba(lhs), let right = rgba(rhs) else { return false }
        return left == right
    }
}

// MARK: - Storage

/// Saves and reads a palette's layer, and brings an older install's colour
/// lists across once. Writes only its own keys; never deletes anything.
nonisolated struct PaletteStore {
    let defaults: UserDefaults

    static func layerKey(_ kind: MarkupKind) -> String { "glossa.markup.layer.\(kind.rawValue).v\(PaletteLayer.currentSchema)" }
    static func backupKey(_ kind: MarkupKind) -> String { "glossa.markup.layer.\(kind.rawValue).backup" }
    static func unreadableKey(_ kind: MarkupKind) -> String { layerKey(kind) + ".unreadable" }
    /// Where PageFlow, and Glossa before this layer, kept whole colour lists.
    static func legacyKey(_ kind: MarkupKind) -> String { kind == .highlight ? "settings.highlightPresets" : "settings.underlinePresets" }

    enum Loaded: Equatable {
        case missing
        case layer(PaletteLayer)
        /// Written by a newer version: read-only here, so it is never overwritten.
        case newerSchema
        case unreadable
    }

    /// A problem with the saved layer that the app can live with: it falls back to the
    /// defaults in memory and leaves the saved data alone.
    enum Issue: Equatable {
        /// Saved by a newer version of the app; read-only here, never overwritten.
        case newerVersion
        /// Not valid data; set aside before anything is written over it.
        case unreadable
    }

    func issue(_ kind: MarkupKind) -> Issue? {
        switch load(kind) {
        case .newerSchema: return .newerVersion
        case .unreadable: return .unreadable
        case .missing, .layer: return nil
        }
    }

    func load(_ kind: MarkupKind) -> Loaded {
        guard let data = defaults.data(forKey: Self.layerKey(kind)) else { return .missing }
        struct Probe: Decodable { var schema: Int }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return .unreadable }
        if probe.schema > PaletteLayer.currentSchema { return .newerSchema }
        guard let layer = try? JSONDecoder().decode(PaletteLayer.self, from: data) else { return .unreadable }
        return .layer(layer)
    }

    /// Saves `layer`. Refuses over a newer version's layer; keeps an unreadable one aside first.
    @discardableResult
    func save(_ layer: PaletteLayer, kind: MarkupKind) -> Bool {
        switch load(kind) {
        case .newerSchema: return false
        case .unreadable:
            if let raw = defaults.data(forKey: Self.layerKey(kind)) { defaults.set(raw, forKey: Self.unreadableKey(kind)) }
        case .missing, .layer: break
        }
        guard let data = try? JSONEncoder().encode(layer) else { return false }
        defaults.set(data, forKey: Self.layerKey(kind))
        return true
    }

    /// Back to the current defaults, keeping the layer it replaces as a backup.
    @discardableResult
    func resetBackingUp(_ kind: MarkupKind) -> Bool {
        if case .newerSchema = load(kind) { return false }
        if let current = defaults.data(forKey: Self.layerKey(kind)) { defaults.set(current, forKey: Self.backupKey(kind)) }
        return save(.empty, kind: kind)
    }

    /// Recovery path for a reset: puts the backed-up layer back (keeping the one it replaces as
    /// the new backup, so the swap can be undone). False if there is no readable backup, or the
    /// saved layer is from a newer version.
    @discardableResult
    func restoreBackup(_ kind: MarkupKind) -> Bool {
        guard let data = defaults.data(forKey: Self.backupKey(kind)),
              let probe = try? JSONDecoder().decode(PaletteLayer.self, from: data),
              probe.schema <= PaletteLayer.currentSchema else { return false }
        if case .newerSchema = load(kind) { return false }
        let current = defaults.data(forKey: Self.layerKey(kind))
        defaults.set(data, forKey: Self.layerKey(kind))
        if let current { defaults.set(current, forKey: Self.backupKey(kind)) } else { defaults.removeObject(forKey: Self.backupKey(kind)) }
        return true
    }

    /// The list to show, after bringing an older list across if this palette has no layer yet.
    func effective(_ kind: MarkupKind) -> [PalettePreset] {
        let base = MarkupPalette.defaults(for: kind)
        migrateIfNeeded(kind)
        guard case .layer(let layer) = load(kind) else { return base }
        return MarkupPalette.resolve(defaults: base, layer: layer)
    }

    // MARK: Migration

    private struct LegacyPreset: Decodable { var name: String; var hex: String }

    /// Idempotent: runs only while there is no layer, and then writes one. The
    /// older lists are left exactly where they are (PageFlow still reads them).
    func migrateIfNeeded(_ kind: MarkupKind) {
        guard load(kind) == .missing else { return }
        var layer = PaletteLayer.empty
        if let data = defaults.data(forKey: Self.legacyKey(kind)),
           let legacy = try? JSONDecoder().decode([LegacyPreset].self, from: data),
           !legacy.isEmpty, !Self.isUncustomised(legacy.map { ($0.name, $0.hex) }) {
            // The reader's own list, kept as it was (names and colours), after the Glossa defaults.
            layer.custom = legacy.map { PalettePreset(key: "user.\(UUID().uuidString)", name: $0.name, hex: $0.hex) }
        }
        save(layer, kind: kind)
    }

    /// Lists a reader never edited: PageFlow's factory colours, the earlier pastel
    /// palette, or today's defaults. Names and colours are both compared, and the
    /// order is not: the same entries in another order are still the same list.
    static func isUncustomised(_ items: [(name: String, hex: String)]) -> Bool {
        func canonical(_ list: [(name: String, hex: String)]) -> [String] {
            list.map { item in
                let rgba = HexColor.rgba(item.hex).map { String($0, radix: 16, uppercase: true) } ?? "invalid:" + item.hex
                return item.name + "|" + rgba
            }.sorted()
        }
        let glossaHighlights = [("Yellow", "#FFFF00"), ("Green", "#00B342"), ("Red", "#D20000"), ("Blue", "#0072C6")]
        let glossaUnderlines = [("Black", "#000000")] + glossaHighlights
        let pastel = MarkupPalette.highlightDefaults.map { ($0.name, $0.hex) }   // the `pastel-1` lists
        let known: [[(name: String, hex: String)]] = [
            glossaHighlights.map { (name: $0.0, hex: $0.1) },
            glossaUnderlines.map { (name: $0.0, hex: $0.1) },
            pastel.map { (name: $0.0, hex: $0.1) },
            MarkupPalette.underlineDefaults.map { (name: $0.name, hex: $0.hex) }
        ]
        let mine = canonical(items)
        return known.contains { canonical($0) == mine }
    }
}
