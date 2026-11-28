//
//  LegacyMigrationPlanner.swift
//  PageFlow
//
//  Decides, key by key, what of PageFlow's preferences Glossa may take: an explicit
//  allowlist, each value checked against the type the app reads it as, and each
//  bookmark judged on its own. It reads a snapshot and returns what it would write;
//  it writes nothing, anywhere.
//
//  Rules, in order:
//   1. Left behind on purpose: `sessionRestore.v1` (only on an explicit request),
//      `hasShownDefaultPDFPrompt` (the new identity has to be able to ask), the window
//      and system state (`NS*`, `Apple*`), and the migration's own marker.
//   2. Allowed: the `settings.*` keys the code actually reads (listed below, each checked
//      against its type), the known `glossa.*` keys, `recentFiles`, `documentViewStates.v2`,
//      `bookmarks:*`, `folderAccessBookmarks.v1`, `droppedImageBookmarks.v1`, the PDF registry
//      and `epubNarrationRate`.
//   3. Anything else is excluded, with the reason in the report: the allowlist is a list,
//      never a prefix. A preference added later is not migrated because it starts with
//      `settings.`; it has to be added here, and the test that compares this list with the
//      keys the code uses fails until it is.
//
//  A value that passes is written byte for byte as it was. It is rebuilt only when a
//  bookmark inside it has to come out, and then only without that bookmark.
//

import Foundation

nonisolated struct LegacyMigrationPlanner: Sendable {
    var inspector = LegacyBookmarkInspector()

    struct Planned {
        var destinationKey: String
        var value: Any
    }

    struct Plan {
        var writes: [Planned] = []
        var items: [MigrationItem] = []
        var findings: [BookmarkFinding] = []
    }

    // MARK: Keys

    static let sessionRestoreKey = "sessionRestore.v1"
    static let recentFilesKey = "recentFiles"
    static let folderAccessKey = "folderAccessBookmarks.v1"
    static let droppedImagesKey = "droppedImageBookmarks.v1"
    static let documentStatesKey = "documentViewStates.v2"
    static let legacyDocumentStatesKey = "documentViewStates.v1"
    static let outlineBookmarkPrefix = "bookmarks:"
    /// The registry's key before and after it was named for Glossa.
    static let registryKey = PDFDocumentRegistry.storageKey
    static let legacyRegistryKey = PDFDocumentRegistry.legacyStorageKey
    static let narrationRateKey = "epubNarrationRate"

    enum Kind { case bool, number, string, json }

    static let knownSettings: [String: Kind] = [
        "settings.topBarAlwaysVisible": .bool, "settings.floatingToolbarAlwaysVisible": .bool,
        "settings.pageIndicatorAlwaysVisible": .bool, "settings.compactTabs": .bool,
        "settings.toolbarMagnificationEnabled": .bool, "settings.showTooltips": .bool,
        "settings.showNavigationRail": .bool, "settings.navigationRailRevealsOnHover": .bool,
        "settings.markdownCentersZoomedOut": .bool, "settings.markdownPageLook": .bool,
        "settings.markdownShowsHiddenContentRow": .bool,
        "settings.toolbarScale": .number, "settings.tabScale": .number, "settings.markdownSideMargin": .number,
        "settings.markdownFontSize": .number, "settings.markdownPageMeasure": .number,
        "settings.markdownColorScheme": .string, "settings.bookTheme": .string, "settings.bookFontFamily": .string,
        "settings.bookFontName": .string, "settings.markdownFontFamily": .string,
        // The colour lists PageFlow kept whole, which `PaletteStore` reads once to build the layer.
        "settings.highlightPresets": .json, "settings.underlinePresets": .json,
        "settings.commentPresets": .json, "settings.customShortcuts": .json,
    ]

    /// `settings.*` keys that exist in PageFlow's preferences but that Glossa's code does not read.
    static let settingsNotMigrated: [String: String] = [
        "settings.markupPaletteVersion": "PageFlow's palette version marker; Glossa keeps its palettes in versioned layers and does not read it",
    ]

    static let knownGlossa: [String: Kind] = [
        "glossa.tabs.scale": .number, "glossa.markdown.pageMeasure": .number, "glossa.export.pdfScale": .number,
        "glossa.markup.layer.highlight.v1": .json, "glossa.markup.layer.underline.v1": .json,
        "glossa.markup.layer.highlight.backup": .json, "glossa.markup.layer.underline.backup": .json,
        "glossa.markup.comment.backup": .json,
    ]

    // MARK: Planning

    func plan(source: [String: Any]) -> Plan {
        var plan = Plan()
        for key in source.keys.sorted() {
            guard let value = source[key] else { continue }
            decide(key, value, in: source, into: &plan)
        }
        return plan
    }

    private func exclude(_ key: String, _ why: String, _ plan: inout Plan) {
        plan.items.append(.init(sourceKey: key, destinationKey: nil, category: .excluded, detail: why))
    }

    private func invalid(_ key: String, _ why: String, _ plan: inout Plan) {
        plan.items.append(.init(sourceKey: key, destinationKey: nil, category: .invalid, detail: why))
    }

    private func transfer(_ key: String, to destination: String? = nil, _ value: Any, category: MigrationCategory = .transferable,
                          detail: String, _ plan: inout Plan) {
        let target = destination ?? key
        plan.writes.append(.init(destinationKey: target, value: value))
        plan.items.append(.init(sourceKey: key, destinationKey: target, category: category, detail: detail))
    }

    private func decide(_ key: String, _ value: Any, in source: [String: Any], into plan: inout Plan) {
        if key == Self.sessionRestoreKey { return exclude(key, "the last session comes back only when the reader asks for it", &plan) }
        if key == "hasShownDefaultPDFPrompt" { return exclude(key, "the new identity has to be able to ask", &plan) }
        if key.hasPrefix("glossa.migration.") { return exclude(key, "the migration's own marker", &plan) }
        if key.hasPrefix("NS") { return exclude(key, "window or system state", &plan) }
        if key.hasPrefix("Apple") { return exclude(key, "system setting", &plan) }
        if key.hasSuffix(".unreadable") { return exclude(key, "a diagnostic copy of data that could not be read", &plan) }

        if key.hasPrefix("settings.") {
            guard let kind = Self.knownSettings[key] else {
                return exclude(key, Self.settingsNotMigrated[key]
                    ?? "not on the settings allowlist: a setting is migrated only when the code is known to read it, whatever its type", &plan)
            }
            if let problem = Self.check(value, as: kind) { return invalid(key, problem, &plan) }
            return transfer(key, value, detail: "setting", &plan)
        }

        if key.hasPrefix("glossa.") && key != Self.registryKey {
            guard let kind = Self.knownGlossa[key] else { return exclude(key, "not on the allowlist", &plan) }
            if let problem = Self.check(value, as: kind) { return invalid(key, problem, &plan) }
            if kind == .json, key.hasPrefix("glossa.markup.layer."), !Self.hasSchema(value) {
                return invalid(key, "a palette layer without a schema number", &plan)
            }
            return transfer(key, value, detail: "Glossa setting", &plan)
        }

        switch key {
        case Self.recentFilesKey: planRecentFiles(key, value, &plan)
        case Self.folderAccessKey: planFolderAccess(key, value, &plan)
        case Self.droppedImagesKey: planDroppedImages(key, value, &plan)
        case Self.registryKey: planRegistry(key, value, &plan)
        case Self.legacyRegistryKey:
            // When the Glossa key is in the source, it is the registry, even if it is unreadable: the
            // older one does not stand in for it (the unreadable key is reported as invalid).
            if source[Self.registryKey] != nil { exclude(key, "the source has \(Self.registryKey); the older registry does not stand in for it, even if that one is unreadable", &plan) }
            else { planRegistry(key, value, &plan) }
        case Self.documentStatesKey:
            if let problem = Self.check(value, as: .json) { invalid(key, problem, &plan) }
            else { transfer(key, value, detail: "reading positions", &plan) }
        case Self.legacyDocumentStatesKey:
            if source[Self.documentStatesKey] != nil { exclude(key, "superseded by documentViewStates.v2", &plan) }
            else if let problem = Self.check(value, as: .json) { invalid(key, problem, &plan) }
            else { transfer(key, value, detail: "reading positions (older format, read as a fallback)", &plan) }
        case Self.narrationRateKey:
            if let problem = Self.check(value, as: .number) { invalid(key, problem, &plan) }
            else { transfer(key, value, detail: "read-aloud speed", &plan) }
        default:
            if key.hasPrefix(Self.outlineBookmarkPrefix) {
                if let problem = Self.check(value, as: .json) { invalid(key, problem, &plan) }
                else { transfer(key, value, detail: "page bookmarks of one document", &plan) }
            } else {
                exclude(key, "not on the allowlist", &plan)
            }
        }
    }

    // MARK: Value checks

    static func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    /// nil when `value` is what the app reads the key as; otherwise why not.
    static func check(_ value: Any, as kind: Kind) -> String? {
        switch kind {
        case .bool:
            return isBool(value) ? nil : "not a Boolean"
        case .number:
            guard let number = value as? NSNumber, !isBool(value) else { return "not a number" }
            return number.doubleValue.isFinite ? nil : "not a finite number"
        case .string:
            return value is String ? nil : "not a string"
        case .json:
            guard let data = value as? Data else { return "not data" }
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil ? nil : "data that is not valid JSON"
        }
    }

    private static func hasSchema(_ value: Any) -> Bool {
        guard let data = value as? Data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let schema = object["schema"] as? NSNumber, !isBool(schema) else { return false }
        return true
    }

    // MARK: Stores that hold bookmarks

    private func finding(_ store: String, _ subject: String, _ result: LegacyBookmarkInspector.Result, _ action: BookmarkFinding.Action,
                         _ plan: inout Plan) {
        plan.findings.append(.init(store: store, subject: subject, outcome: result.outcome, action: action))
    }

    /// `recentFiles`: a JSON list of entries, each a URL and an optional bookmark.
    private struct RecentEntry: Codable {
        var url: URL
        var securityScopedBookmarkData: Data?
    }

    private func planRecentFiles(_ key: String, _ value: Any, _ plan: inout Plan) {
        guard let data = value as? Data, let entries = try? JSONDecoder().decode([RecentEntry].self, from: data) else {
            return invalid(key, "not a list of recent files", &plan)
        }
        var changed = false
        var kept: [RecentEntry] = []
        for var entry in entries {
            guard let bookmark = entry.securityScopedBookmarkData else { kept.append(entry); continue }
            let result = inspector.inspect(bookmark)
            switch result {
            case .valid:
                finding(key, entry.url.path, result, .kept, &plan)
                kept.append(entry)
            case .stale(let moved):
                finding(key, entry.url.path, result, .keptWithoutBookmark, &plan)
                entry.url = moved
                entry.securityScopedBookmarkData = nil
                changed = true
                kept.append(entry)
            case .unreachable:
                finding(key, entry.url.path, result, .keptWithoutBookmark, &plan)
                entry.securityScopedBookmarkData = nil
                changed = true
                kept.append(entry)
            case .unresolvable:
                changed = true
                if FileManager.default.fileExists(atPath: entry.url.path) {
                    finding(key, entry.url.path, result, .keptWithoutBookmark, &plan)
                    entry.securityScopedBookmarkData = nil
                    kept.append(entry)
                } else {
                    finding(key, entry.url.path, result, .dropped, &plan)
                }
            }
        }
        guard changed else { return transfer(key, value, detail: "recent files, every bookmark valid", &plan) }
        guard let rebuilt = try? JSONEncoder().encode(kept) else { return invalid(key, "recent files that could not be written back", &plan) }
        transfer(key, rebuilt, category: .needsVerification, detail: "recent files; some bookmarks need the reader's permission again", &plan)
    }

    /// `folderAccessBookmarks.v1`: a dictionary, folder path to bookmark.
    private func planFolderAccess(_ key: String, _ value: Any, _ plan: inout Plan) {
        guard let dictionary = value as? [String: Data] else { return invalid(key, "not a dictionary of bookmarks", &plan) }
        var kept: [String: Data] = [:]
        for path in dictionary.keys.sorted() {
            let result = inspector.inspect(dictionary[path]!)
            if case .valid = result {
                kept[path] = dictionary[path]
                finding(key, path, result, .kept, &plan)
            } else {
                finding(key, path, result, .dropped, &plan)
            }
        }
        if kept.count == dictionary.count { return transfer(key, value, detail: "folder permissions, every bookmark valid", &plan) }
        if kept.isEmpty {
            plan.items.append(.init(sourceKey: key, destinationKey: nil, category: .needsVerification,
                                    detail: "no folder permission could be verified; each folder has to be allowed again"))
            return
        }
        transfer(key, kept, category: .needsVerification, detail: "folder permissions; the ones that failed have to be allowed again", &plan)
    }

    /// `droppedImageBookmarks.v1`: a list of `{path, bookmark}`.
    private func planDroppedImages(_ key: String, _ value: Any, _ plan: inout Plan) {
        guard let list = value as? [[String: Any]] else { return invalid(key, "not a list of bookmarks", &plan) }
        var kept: [[String: Any]] = []
        for entry in list {
            guard let path = entry["path"] as? String, let bookmark = entry["bookmark"] as? Data else {
                plan.findings.append(.init(store: key, subject: "(entry without a path or a bookmark)", outcome: .unresolvable, action: .dropped))
                continue
            }
            let result = inspector.inspect(bookmark)
            if case .valid = result { kept.append(entry); finding(key, path, result, .kept, &plan) }
            else { finding(key, path, result, .dropped, &plan) }
        }
        if kept.count == list.count { return transfer(key, value, detail: "dropped-image permissions, every bookmark valid", &plan) }
        if kept.isEmpty {
            plan.items.append(.init(sourceKey: key, destinationKey: nil, category: .needsVerification,
                                    detail: "no dropped-image permission could be verified"))
            return
        }
        transfer(key, kept, category: .needsVerification, detail: "dropped-image permissions; the ones that failed are left out", &plan)
    }

    /// The PDF registry: a JSON dictionary of records, each with a bookmark and notes with bookmarks.
    private func planRegistry(_ key: String, _ value: Any, _ plan: inout Plan) {
        guard let data = value as? Data, var records = try? JSONDecoder().decode([String: PDFDocumentRecord].self, from: data) else {
            return invalid(key, "not a registry of PDF documents", &plan)
        }
        var changed = false
        for id in records.keys.sorted() {
            var record = records[id]!
            if let bookmark = record.bookmark {
                let result = inspector.inspect(bookmark)
                if case .valid = result { finding(key, record.lastPath, result, .kept, &plan) }
                else {
                    finding(key, record.lastPath, result, .keptWithoutBookmark, &plan)
                    record.bookmark = nil
                    changed = true
                }
            }
            for index in record.notes.indices {
                guard let bookmark = record.notes[index].bookmark else { continue }
                let result = inspector.inspect(bookmark)
                if case .valid = result { finding(key, record.notes[index].path, result, .kept, &plan) }
                else {
                    finding(key, record.notes[index].path, result, .keptWithoutBookmark, &plan)
                    record.notes[index].bookmark = nil
                    changed = true
                }
            }
            records[id] = record
        }
        guard changed else { return transfer(key, to: Self.registryKey, value, detail: "PDF registry, every bookmark valid", &plan) }
        guard let rebuilt = try? JSONEncoder().encode(records) else { return invalid(key, "a registry that could not be written back", &plan) }
        transfer(key, to: Self.registryKey, rebuilt, category: .needsVerification, detail: "PDF registry; some documents have to be found again by path", &plan)
    }
}
