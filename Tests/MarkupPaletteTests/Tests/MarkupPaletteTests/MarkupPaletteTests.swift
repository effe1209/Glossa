import XCTest
import PDFKit
@testable import MarkupPalette

/// An in-memory stand-in for the preferences: nothing reaches the disk, `UserDefaults` or the
/// reader's real preferences domain.
private final class MemoryDefaults: PaletteStorage {
    private var values: [String: Any] = [:]
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    func dictionaryRepresentation() -> [String: Any] { values }
}

final class MarkupPaletteTests: XCTestCase {
    /// A throwaway in-memory store, so no test touches real preferences.
    private func makeDefaults() -> MemoryDefaults { MemoryDefaults() }

    private func color(_ hex: String) -> NSColor { HexColor.color(fromHex: hex)! }
    private let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    private func encode(_ presets: [(String, String)]) -> Data {
        struct P: Encodable { var id = UUID(); var name: String; var hex: String }
        return try! JSONEncoder().encode(presets.map { P(name: $0.0, hex: $0.1) })
    }

    // MARK: Defaults

    func testHighlightPaletteIsTheOfficialOne() {
        XCTAssertEqual(MarkupPalette.highlightDefaults.map(\.hex), ["#FFF0A8", "#C8E3CC", "#C9DFF2", "#F2CED5"])
        XCTAssertEqual(MarkupPalette.highlightDefaults.map(\.name), ["Yellow", "Green", "Blue", "Pink"])
        XCTAssertEqual(MarkupPalette.defaultHighlightHex, "#FFF0A8")
    }

    func testUnderlinePaletteIsTheApprovedDarkerOne() {
        XCTAssertEqual(MarkupPalette.underlineDefaults.map(\.hex), ["#B8860B", "#4F9A63", "#3F83C0", "#D2607C"])
        XCTAssertEqual(MarkupPalette.underlineDefaults.map(\.name), ["Yellow", "Green", "Blue", "Pink"])
        XCTAssertEqual(MarkupPalette.defaultUnderlineHex, "#B8860B")
        XCTAssertTrue(Set(MarkupPalette.underlineDefaults.map(\.hex)).isDisjoint(with: MarkupPalette.highlightDefaults.map(\.hex)))
        XCTAssertTrue(Set(MarkupPalette.underlineDefaults.map(\.key)).isDisjoint(with: MarkupPalette.highlightDefaults.map(\.key)))
    }

    func testEveryUnderlineShowsOnWhite() throws {
        for preset in MarkupPalette.underlineDefaults {
            let ratio = try XCTUnwrap(ColorContrast.ratio(color(preset.hex), against: white))
            XCTAssertGreaterThanOrEqual(ratio, 3, preset.hex)
        }
    }

    // MARK: Resolving, new presets, empty lists

    func testNewPresetTakesTheFirstDefaultNotAlreadyThere() {
        let all = MarkupPalette.highlightDefaults
        XCTAssertEqual(MarkupPalette.newPresetHex(for: .highlight, existing: []), "#FFF0A8")
        XCTAssertEqual(MarkupPalette.newPresetHex(for: .highlight, existing: [all[0]]), "#C8E3CC")
        XCTAssertEqual(MarkupPalette.newPresetHex(for: .highlight, existing: all), "#FFF0A8")
        XCTAssertEqual(MarkupPalette.newPresetHex(for: .underline, existing: []), "#B8860B")
    }

    func testAnEmptyListFallsBackToTheDefaults() {
        let layer = PaletteLayer(hiddenDefaults: MarkupPalette.highlightDefaults.map(\.key))
        XCTAssertEqual(MarkupPalette.resolve(defaults: MarkupPalette.highlightDefaults, layer: layer), MarkupPalette.highlightDefaults)
        XCTAssertEqual(MarkupPalette.resolve(defaults: MarkupPalette.highlightDefaults, layer: .empty), MarkupPalette.highlightDefaults)
    }

    func testLayerRoundTripsThroughResolve() {
        let defaults = MarkupPalette.highlightDefaults
        var effective = defaults
        effective[1].hex = "#00FF00"                       // changed a default
        effective.remove(at: 2)                              // removed a default
        effective.append(PalettePreset(key: "user.a", name: "Mine", hex: "#112233"))
        effective.insert(effective.removeLast(), at: 0)      // and reordered
        let layer = MarkupPalette.layer(from: effective, defaults: defaults)
        XCTAssertEqual(MarkupPalette.resolve(defaults: defaults, layer: layer), effective)
        XCTAssertEqual(MarkupPalette.layer(from: defaults, defaults: defaults), .empty)
    }

    // MARK: Reset

    func testResetRestoresTheDefaultsAndKeepsABackup() {
        let store = PaletteStore(defaults: makeDefaults())
        let custom = PaletteLayer(custom: [PalettePreset(key: "user.a", name: "Mine", hex: "#112233")],
                                  hiddenDefaults: MarkupPalette.highlightDefaults.map(\.key), order: ["user.a"])
        store.save(custom, kind: .highlight)
        XCTAssertEqual(store.effective(.highlight).map(\.hex), ["#112233"])
        store.resetBackingUp(.highlight)
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
        let backup = store.defaults.data(forKey: PaletteStore.backupKey(.highlight))
        XCTAssertEqual(backup.flatMap { try? JSONDecoder().decode(PaletteLayer.self, from: $0) }, custom)
    }

    // MARK: Persistence

    func testChangesSurviveARelaunch() {
        let defaults = makeDefaults()
        var shown = PaletteStore(defaults: defaults).effective(.underline)
        shown[0].hex = "#102030"
        shown.append(PalettePreset(key: "user.z", name: "Extra", hex: "#AABBCC"))
        PaletteStore(defaults: defaults).save(MarkupPalette.layer(from: shown, defaults: MarkupPalette.underlineDefaults), kind: .underline)
        XCTAssertEqual(PaletteStore(defaults: defaults).effective(.underline), shown)
    }

    func testANewerSchemaIsReadOnlyAndAnUnreadableLayerIsKeptAside() {
        let defaults = makeDefaults()
        let store = PaletteStore(defaults: defaults)
        let future = Data(#"{"schema": 99, "custom": []}"#.utf8)
        defaults.set(future, forKey: PaletteStore.layerKey(.highlight))
        XCTAssertEqual(store.load(.highlight), .newerSchema)
        XCTAssertFalse(store.save(.empty, kind: .highlight))
        XCTAssertEqual(defaults.data(forKey: PaletteStore.layerKey(.highlight)), future)
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)

        let junk = Data("not json".utf8)
        defaults.set(junk, forKey: PaletteStore.layerKey(.underline))
        XCTAssertEqual(store.load(.underline), .unreadable)
        XCTAssertTrue(store.save(.empty, kind: .underline))
        XCTAssertEqual(defaults.data(forKey: PaletteStore.unreadableKey(.underline)), junk)
    }

    // MARK: Upgrade from pastel-1 and from PageFlow

    func testUpgradeWithNoOlderListsGivesTheDefaults() {
        let defaults = makeDefaults()
        defaults.set("pastel-1", forKey: "settings.markupPaletteVersion")
        let store = PaletteStore(defaults: defaults)
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
        XCTAssertEqual(store.effective(.underline), MarkupPalette.underlineDefaults)
        XCTAssertEqual(store.load(.highlight), .layer(.empty))
    }

    func testUneditedOlderListsAreNotTreatedAsCustomisations() {
        let defaults = makeDefaults()
        defaults.set(encode([("Yellow", "#FFFF00"), ("Green", "#00B342"), ("Red", "#D20000"), ("Blue", "#0072C6")]),
                     forKey: "settings.highlightPresets")                                   // PageFlow's factory list
        defaults.set(encode(MarkupPalette.highlightDefaults.map { ($0.name, $0.hex) }),
                     forKey: "settings.underlinePresets")                                   // the pastel-1 list
        let store = PaletteStore(defaults: defaults)
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
        XCTAssertEqual(store.effective(.underline), MarkupPalette.underlineDefaults)
    }

    func testACustomisedOlderListIsKeptAsItWasAndNothingIsDeleted() {
        let defaults = makeDefaults()
        let mine = [("Lemon", "#FFFF66"), ("Sky", "#66CCFF")]
        defaults.set(encode(mine), forKey: "settings.highlightPresets")
        defaults.set("pastel-1", forKey: "settings.markupPaletteVersion")
        let store = PaletteStore(defaults: defaults)
        let shown = store.effective(.highlight)
        // The Glossa defaults, then the reader's own list with its names and colours.
        XCTAssertEqual(shown.map(\.hex), MarkupPalette.highlightDefaults.map(\.hex) + ["#FFFF66", "#66CCFF"])
        XCTAssertEqual(shown.suffix(2).map(\.name), ["Lemon", "Sky"])
        XCTAssertTrue(shown.suffix(2).allSatisfy { $0.key.hasPrefix("user.") })
        XCTAssertNotNil(defaults.data(forKey: "settings.highlightPresets"))
        XCTAssertEqual(defaults.string(forKey: "settings.markupPaletteVersion"), "pastel-1")
        // Reset drops the reader's own list (a backup is kept).
        store.resetBackingUp(.highlight)
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
    }

    func testTheSameOlderListInAnotherOrderIsStillUncustomised() {
        let defaults = makeDefaults()
        defaults.set(encode([("Blue", "#0072C6"), ("Yellow", "#FFFF00"), ("Red", "#D20000"), ("Green", "#00B342")]),
                     forKey: "settings.highlightPresets")
        XCTAssertEqual(PaletteStore(defaults: defaults).effective(.highlight), MarkupPalette.highlightDefaults)
    }

    func testARenamedOrRecolouredOlderListIsACustomisation() {
        let renamed = makeDefaults()
        renamed.set(encode([("Sun", "#FFFF00"), ("Green", "#00B342"), ("Red", "#D20000"), ("Blue", "#0072C6")]),
                    forKey: "settings.highlightPresets")
        XCTAssertEqual(PaletteStore(defaults: renamed).effective(.highlight).count, MarkupPalette.highlightDefaults.count + 4)
        let recoloured = makeDefaults()
        recoloured.set(encode([("Yellow", "#FFFF01"), ("Green", "#00B342"), ("Red", "#D20000"), ("Blue", "#0072C6")]),
                       forKey: "settings.highlightPresets")
        XCTAssertEqual(PaletteStore(defaults: recoloured).effective(.highlight).count, MarkupPalette.highlightDefaults.count + 4)
    }

    func testNothingIsDuplicatedAcrossRuns() {
        let defaults = makeDefaults()
        defaults.set(encode([("Lemon", "#FFFF66")]), forKey: "settings.highlightPresets")
        let store = PaletteStore(defaults: defaults)
        let once = store.effective(.highlight)
        XCTAssertEqual(PaletteStore(defaults: defaults).effective(.highlight), once)
        XCTAssertEqual(once.count, MarkupPalette.highlightDefaults.count + 1)
    }

    func testPageFlowsKeysAreNeverWrittenByGlossa() {
        let defaults = makeDefaults()
        let store = PaletteStore(defaults: defaults)
        var shown = store.effective(.highlight)
        shown[0].hex = "#123456"
        store.save(MarkupPalette.layer(from: shown, defaults: MarkupPalette.highlightDefaults), kind: .highlight)
        store.resetBackingUp(.underline)
        XCTAssertNil(defaults.data(forKey: "settings.highlightPresets"))
        XCTAssertNil(defaults.data(forKey: "settings.underlinePresets"))
        XCTAssertNil(defaults.object(forKey: "settings.markupPaletteVersion"))
    }

    func testStorageKeysUseTheGlossaNamespace() {
        XCTAssertEqual(PaletteStore.layerKey(.highlight), "glossa.markup.layer.highlight.v1")
        XCTAssertEqual(PaletteStore.layerKey(.underline), "glossa.markup.layer.underline.v1")
        XCTAssertEqual(PaletteStore.backupKey(.highlight), "glossa.markup.layer.highlight.backup")
        XCTAssertEqual(PaletteStore.backupKey(.underline), "glossa.markup.layer.underline.backup")
    }

    func testIdentifiersAreStableAndNamespaced() {
        XCTAssertEqual(MarkupPalette.highlightDefaults.map(\.key),
                       ["glossa.highlight.yellow", "glossa.highlight.green", "glossa.highlight.blue", "glossa.highlight.pink"])
        XCTAssertEqual(MarkupPalette.underlineDefaults.map(\.key),
                       ["glossa.underline.yellow", "glossa.underline.green", "glossa.underline.blue", "glossa.underline.pink"])
    }

    func testIncompatibleSavedDataIsReported() {
        let defaults = makeDefaults()
        let store = PaletteStore(defaults: defaults)
        XCTAssertNil(store.issue(.highlight))
        defaults.set(Data(#"{"schema": 2}"#.utf8), forKey: PaletteStore.layerKey(.highlight))
        defaults.set(Data("junk".utf8), forKey: PaletteStore.layerKey(.underline))
        XCTAssertEqual(store.issue(.highlight), .newerVersion)
        XCTAssertEqual(store.issue(.underline), .unreadable)
        // The data stays where it is, and the defaults carry on in memory.
        XCTAssertEqual(defaults.data(forKey: PaletteStore.layerKey(.highlight)), Data(#"{"schema": 2}"#.utf8))
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
    }

    func testMigrationIsIdempotentAndIgnoresLaterOlderWrites() {
        let defaults = makeDefaults()
        let store = PaletteStore(defaults: defaults)
        _ = store.effective(.highlight)
        let first = defaults.data(forKey: PaletteStore.layerKey(.highlight))
        _ = store.effective(.highlight)
        XCTAssertEqual(defaults.data(forKey: PaletteStore.layerKey(.highlight)), first)
        // PageFlow writing its own list afterwards must not reach Glossa's palette.
        defaults.set(encode([("Old", "#FFFF00")]), forKey: "settings.highlightPresets")
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
    }

    // MARK: A later release changing the defaults

    func testChangingTheDefaultsLaterKeepsTheReadersChanges() {
        let old = MarkupPalette.highlightDefaults
        var shown = old
        shown[0].hex = "#101010"                                  // edited by the reader
        shown.remove(at: 3)                                        // removed by the reader
        shown.append(PalettePreset(key: "user.q", name: "Mine", hex: "#ABCDEF"))
        let layer = MarkupPalette.layer(from: shown, defaults: old)

        var next = old                                             // the new release's palette
        next[1].hex = "#00AA00"                                    // changed an untouched default
        next[0].hex = "#FFFFFF"                                    // changed one the reader edited
        next.append(PalettePreset(key: "glossa.orange", name: "Orange", hex: "#FFCC99"))   // added one
        let resolved = MarkupPalette.resolve(defaults: next, layer: layer)

        XCTAssertEqual(resolved.first { $0.key == "glossa.highlight.yellow" }?.hex, "#101010")      // reader's edit wins
        XCTAssertEqual(resolved.first { $0.key == "glossa.highlight.green" }?.hex, "#00AA00")       // follows the new default
        XCTAssertNil(resolved.first { $0.key == "glossa.highlight.pink" })                           // stays removed
        XCTAssertNotNil(resolved.first { $0.key == "user.q" })                             // custom kept
        let keys = resolved.map(\.key)
        // Not reordered: the new default joins the defaults, ahead of the reader's own presets.
        XCTAssertLessThan(keys.firstIndex(of: "glossa.orange")!, keys.firstIndex(of: "user.q")!)
        XCTAssertGreaterThan(keys.firstIndex(of: "glossa.orange")!, keys.firstIndex(of: "glossa.highlight.green")!)
    }

    func testDefaultsComeFirstUnlessTheReaderReordered() {
        let defaults = MarkupPalette.highlightDefaults
        let mine = PalettePreset(key: "user.m", name: "Mine", hex: "#112233")
        // Natural order: nothing about order is saved.
        XCTAssertEqual(MarkupPalette.layer(from: defaults + [mine], defaults: defaults).order, [])
        XCTAssertEqual(MarkupPalette.resolve(defaults: defaults, layer: MarkupPalette.layer(from: defaults + [mine], defaults: defaults)).last, mine)
        // Reordered by the reader: kept, and a default added later goes to the very end.
        let reordered = [mine] + defaults
        let layer = MarkupPalette.layer(from: reordered, defaults: defaults)
        XCTAssertEqual(layer.order, reordered.map(\.key))
        let extra = PalettePreset(key: "glossa.highlight.orange", name: "Orange", hex: "#FFCC99")
        XCTAssertEqual(MarkupPalette.resolve(defaults: defaults + [extra], layer: layer).map(\.key),
                       reordered.map(\.key) + ["glossa.highlight.orange"])
    }

    func testRestoringTheBackupUndoesAReset() {
        let store = PaletteStore(defaults: makeDefaults())
        let mine = PaletteLayer(custom: [PalettePreset(key: "user.a", name: "Mine", hex: "#112233")])
        store.save(mine, kind: .highlight)
        XCTAssertFalse(store.restoreBackup(.underline))              // no backup yet
        store.resetBackingUp(.highlight)
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
        XCTAssertTrue(store.restoreBackup(.highlight))
        XCTAssertEqual(store.load(.highlight), .layer(mine))
        // The swap itself can be undone: the reset layer is now the backup.
        XCTAssertTrue(store.restoreBackup(.highlight))
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
    }

    func testResetOnlyTouchesItsOwnKeys() {
        let defaults = makeDefaults()
        defaults.set("keep", forKey: "settings.somethingElse")
        defaults.set(encode([("Lemon", "#FFFF66")]), forKey: "settings.highlightPresets")
        let before = defaults.data(forKey: "settings.highlightPresets")
        let store = PaletteStore(defaults: defaults)
        _ = store.effective(.highlight)
        store.resetBackingUp(.highlight)
        XCTAssertEqual(defaults.string(forKey: "settings.somethingElse"), "keep")
        XCTAssertEqual(defaults.data(forKey: "settings.highlightPresets"), before)
    }

    // MARK: Initial colours

    func testTheInitialSelectedColoursAreTheFirstOfEachPalette() throws {
        XCTAssertEqual(MarkupPalette.defaultHighlightHex, MarkupPalette.highlightDefaults.first?.hex)
        XCTAssertEqual(MarkupPalette.defaultUnderlineHex, MarkupPalette.underlineDefaults.first?.hex)
        XCTAssertEqual(HexColor.hex(from: MarkupPalette.defaultHighlightColor), "#FFF0A8FF")
        XCTAssertEqual(HexColor.hex(from: MarkupPalette.defaultUnderlineColor), "#B8860BFF")
        let store = PaletteStore(defaults: makeDefaults())
        XCTAssertEqual(store.effective(.highlight).first?.hex, MarkupPalette.defaultHighlightHex)
        XCTAssertEqual(store.effective(.underline).first?.hex, MarkupPalette.defaultUnderlineHex)
    }

    // MARK: Contrast maths

    func testRelativeLuminanceFollowsWCAG() throws {
        func luminance(_ hex: String) throws -> Double { try XCTUnwrap(ColorContrast.relativeLuminance(of: color(hex))) }
        XCTAssertEqual(try luminance("#FFFFFF"), 1, accuracy: 0.0001)
        XCTAssertEqual(try luminance("#000000"), 0, accuracy: 0.0001)
        XCTAssertEqual(try luminance("#FF0000"), 0.2126, accuracy: 0.0005)
        XCTAssertEqual(try luminance("#00FF00"), 0.7152, accuracy: 0.0005)
        XCTAssertEqual(try luminance("#0000FF"), 0.0722, accuracy: 0.0005)
        XCTAssertEqual(try luminance("#808080"), 0.2159, accuracy: 0.0005)      // mid grey, from the WCAG formula
    }

    func testContrastRatioMatchesKnownValues() throws {
        // #767676 on white is the classic 4.54:1 (just over AA for text).
        XCTAssertEqual(try XCTUnwrap(ColorContrast.ratio(color("#767676"), against: white)), 4.54, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(ColorContrast.ratio(white, against: color("#767676"))), 4.54, accuracy: 0.01)   // symmetric
        XCTAssertEqual(try XCTUnwrap(ColorContrast.ratio(color("#FFF0A8"), against: white)), 1.15, accuracy: 0.01)
    }

    func testTheHighlightPaletteStaysPaleOnPurpose() throws {
        // Highlights are tints behind dark text, not lines: they stay as approved, whatever the underline rule.
        for preset in MarkupPalette.highlightDefaults {
            XCTAssertLessThan(try XCTUnwrap(ColorContrast.ratio(color(preset.hex), against: white)), 1.5, preset.hex)
        }
    }

    // MARK: New presets

    func testANewPresetHasAStableUUIDKeyAndPersists() throws {
        let first = MarkupPalette.makeCustomPreset(for: .highlight, existing: MarkupPalette.highlightDefaults)
        let second = MarkupPalette.makeCustomPreset(for: .highlight, existing: MarkupPalette.highlightDefaults)
        XCTAssertTrue(first.key.hasPrefix("user."))
        XCTAssertNotNil(UUID(uuidString: String(first.key.dropFirst("user.".count))))
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertEqual(first.name, "New")
        XCTAssertEqual(first.hex, "#FFF0A8")                         // every default is present: the first again

        let store = PaletteStore(defaults: makeDefaults())
        var shown = store.effective(.highlight)
        shown.append(first)
        store.save(MarkupPalette.layer(from: shown, defaults: MarkupPalette.highlightDefaults), kind: .highlight)
        let reloaded = PaletteStore(defaults: store.defaults).effective(.highlight)
        XCTAssertEqual(reloaded.last, first)                          // same key after a relaunch
    }

    func testANewPresetTakesTheFirstUnusedColourOfItsOwnPalette() {
        var shown = MarkupPalette.underlineDefaults
        shown.removeSubrange(1...2)                                   // Green and Blue are free
        XCTAssertEqual(MarkupPalette.makeCustomPreset(for: .underline, existing: shown).hex, "#4F9A63")
        XCTAssertEqual(MarkupPalette.makeCustomPreset(for: .underline, existing: MarkupPalette.underlineDefaults).hex, "#B8860B")
    }

    // MARK: The effective palette, one rule at a time

    func testDefaultsPlusCustomPresets() {
        let mine = [PalettePreset(key: "user.1", name: "A", hex: "#111111"), PalettePreset(key: "user.2", name: "B", hex: "#222222")]
        let resolved = MarkupPalette.resolve(defaults: MarkupPalette.highlightDefaults, layer: PaletteLayer(custom: mine))
        XCTAssertEqual(resolved, MarkupPalette.highlightDefaults + mine)
    }

    func testOverridesChangeNameAndColourOnly() {
        let layer = PaletteLayer(overrides: ["glossa.highlight.green": .init(name: "Mint", hex: "#00FF99")])
        let resolved = MarkupPalette.resolve(defaults: MarkupPalette.highlightDefaults, layer: layer)
        XCTAssertEqual(resolved[1], PalettePreset(key: "glossa.highlight.green", name: "Mint", hex: "#00FF99"))
        XCTAssertEqual(resolved[0], MarkupPalette.highlightDefaults[0])
        let nameOnly = MarkupPalette.resolve(defaults: MarkupPalette.highlightDefaults,
                                             layer: PaletteLayer(overrides: ["glossa.highlight.pink": .init(name: "Rose")]))
        XCTAssertEqual(nameOnly[3].hex, "#F2CED5")
    }

    func testHiddenDefaultsAreLeftOut() {
        let resolved = MarkupPalette.resolve(defaults: MarkupPalette.highlightDefaults,
                                             layer: PaletteLayer(hiddenDefaults: ["glossa.highlight.green", "glossa.highlight.blue"]))
        XCTAssertEqual(resolved.map(\.key), ["glossa.highlight.yellow", "glossa.highlight.pink"])
    }

    func testACustomOrderIsHonoured() {
        let mine = PalettePreset(key: "user.1", name: "A", hex: "#111111")
        let order = ["user.1", "glossa.highlight.pink", "glossa.highlight.yellow", "glossa.highlight.green", "glossa.highlight.blue"]
        let resolved = MarkupPalette.resolve(defaults: MarkupPalette.highlightDefaults, layer: PaletteLayer(custom: [mine], order: order))
        XCTAssertEqual(resolved.map(\.key), order)
    }

    // MARK: Migration: the rest of the cases

    /// Every key in the domain except the ones Glossa itself writes.
    private func legacySnapshot(_ defaults: MemoryDefaults) -> [String: Data] {
        var out: [String: Data] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where !key.hasPrefix("glossa.") {
            if let data = value as? Data { out[key] = data } else if let text = value as? String { out[key] = Data(text.utf8) }
        }
        return out
    }

    func testAnExistingGlossaLayerIsUsedAndTheOlderListsAreIgnored() {
        let defaults = makeDefaults()
        let layer = PaletteLayer(custom: [PalettePreset(key: "user.keep", name: "Keep", hex: "#0A0B0C")])
        PaletteStore(defaults: defaults).save(layer, kind: .highlight)
        defaults.set(encode([("Other", "#FF00FF")]), forKey: "settings.highlightPresets")
        let shown = PaletteStore(defaults: defaults).effective(.highlight)
        XCTAssertEqual(shown, MarkupPalette.highlightDefaults + layer.custom)
        XCTAssertFalse(shown.contains { $0.hex == "#FF00FF" })
    }

    func testMalformedOlderDataIsLeftAloneAndTheDefaultsShow() {
        let defaults = makeDefaults()
        let junk = Data("definitely not json".utf8)
        let wrongShape = Data(#"{"hello": "world"}"#.utf8)
        defaults.set(junk, forKey: "settings.highlightPresets")
        defaults.set(wrongShape, forKey: "settings.underlinePresets")
        let before = legacySnapshot(defaults)
        let store = PaletteStore(defaults: defaults)
        XCTAssertEqual(store.effective(.highlight), MarkupPalette.highlightDefaults)
        XCTAssertEqual(store.effective(.underline), MarkupPalette.underlineDefaults)
        XCTAssertEqual(legacySnapshot(defaults), before)              // not rewritten, not deleted
        XCTAssertEqual(defaults.data(forKey: "settings.highlightPresets"), junk)
    }

    func testOlderKeysAreNeverDeletedOrRewrittenInAnyScenario() {
        let scenarios: [(String, [String: Data])] = [
            ("none", [:]),
            ("pageflow", ["settings.highlightPresets": encode([("Yellow", "#FFFF00"), ("Green", "#00B342"), ("Red", "#D20000"), ("Blue", "#0072C6")]),
                          "settings.underlinePresets": encode([("Black", "#000000"), ("Yellow", "#FFFF00"), ("Green", "#00B342"), ("Red", "#D20000"), ("Blue", "#0072C6")])]),
            ("pastel", ["settings.highlightPresets": encode(MarkupPalette.highlightDefaults.map { ($0.name, $0.hex) })]),
            ("custom", ["settings.highlightPresets": encode([("Lemon", "#FFFF66")]), "settings.underlinePresets": encode([("Ink", "#101010")])]),
            ("malformed", ["settings.highlightPresets": Data("}{".utf8)])
        ]
        for (name, seed) in scenarios {
            let defaults = makeDefaults()
            for (key, data) in seed { defaults.set(data, forKey: key) }
            defaults.set("pastel-1", forKey: "settings.markupPaletteVersion")
            defaults.set("untouched", forKey: "settings.somethingElse")
            let before = legacySnapshot(defaults)
            let store = PaletteStore(defaults: defaults)
            for kind in MarkupKind.allCases { _ = store.effective(kind); _ = store.effective(kind) }   // twice
            store.resetBackingUp(.highlight)
            XCTAssertEqual(legacySnapshot(defaults), before, name)
        }
    }

    func testAFutureSchemaIsNotMigratedOver() {
        let defaults = makeDefaults()
        let future = Data(##"{"schema": 7, "custom": [{"key": "user.x", "name": "X", "hex": "#010203"}]}"##.utf8)
        defaults.set(future, forKey: PaletteStore.layerKey(.underline))
        defaults.set(encode([("Old", "#123456")]), forKey: "settings.underlinePresets")
        let store = PaletteStore(defaults: defaults)
        XCTAssertEqual(store.effective(.underline), MarkupPalette.underlineDefaults)
        XCTAssertEqual(defaults.data(forKey: PaletteStore.layerKey(.underline)), future)
        XCTAssertEqual(store.issue(.underline), .newerVersion)
    }

    // MARK: EPUB annotations, from serialized fixtures

    /// Highlights as the app saves them (`EPUBAnnotationStore`: default `JSONEncoder`, sorted keys).
    private let epubFixture = """
    [
      {"chapterIndex":0,"color":"#FFFF00","createdAt":700000000,"excerpt":"old yellow","id":"11111111-1111-1111-1111-111111111111","length":10,"location":4,"style":"tint"},
      {"chapterIndex":1,"color":"#FFF0A8","createdAt":700000100,"excerpt":"new yellow","id":"22222222-2222-2222-2222-222222222222","length":8,"location":0,"style":"underline"},
      {"chapterIndex":2,"color":"#00B342FF","createdAt":700000200,"excerpt":"with alpha","id":"33333333-3333-3333-3333-333333333333","length":3,"location":9,"style":"tint","note":"kept"},
      {"chapterIndex":3,"color":"not-a-colour","createdAt":700000300,"excerpt":"unreadable","id":"44444444-4444-4444-4444-444444444444","length":5,"location":2,"style":"tint"}
    ]
    """

    private func decodeFixture() throws -> [EPUBHighlight] {
        try JSONDecoder().decode([EPUBHighlight].self, from: Data(epubFixture.utf8))
    }

    func testEPUBHighlightColoursSurviveEveryPaletteOperation() throws {
        let before = try decodeFixture().map(\.color)
        XCTAssertEqual(before, ["#FFFF00", "#FFF0A8", "#00B342FF", "not-a-colour"])
        let defaults = makeDefaults()
        let store = PaletteStore(defaults: defaults)
        defaults.set(encode([("Old", "#FFFF00")]), forKey: "settings.highlightPresets")
        _ = store.effective(.highlight); _ = store.effective(.underline)
        var shown = store.effective(.highlight)
        shown[0].hex = "#000001"
        store.save(MarkupPalette.layer(from: shown, defaults: MarkupPalette.highlightDefaults), kind: .highlight)
        store.resetBackingUp(.highlight); store.resetBackingUp(.underline)
        store.restoreBackup(.highlight)
        XCTAssertEqual(try decodeFixture().map(\.color), before)
    }

    func testEPUBSerializationIsUnchanged() throws {
        let highlights = try decodeFixture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let object = try JSONSerialization.jsonObject(with: try encoder.encode(highlights)) as? [[String: Any]]
        let first = try XCTUnwrap(object?.first)
        XCTAssertEqual(Set(first.keys), ["chapterIndex", "color", "createdAt", "excerpt", "id", "length", "location", "style"])
        XCTAssertEqual(object?.compactMap { $0["color"] as? String }, ["#FFFF00", "#FFF0A8", "#00B342FF", "not-a-colour"])
        XCTAssertEqual(object?[2]["note"] as? String, "kept")
        // A round trip changes nothing.
        XCTAssertEqual(try JSONDecoder().decode([EPUBHighlight].self, from: try encoder.encode(highlights)), highlights)
    }

    func testTheLegacyEPUBRenderFallbackIsUnchanged() throws {
        let highlights = try decodeFixture()
        // Colours that parse draw as themselves.
        XCTAssertEqual(HexColor.hex(from: highlights[0].nsColor), "#FFFF00FF")
        XCTAssertEqual(HexColor.hex(from: highlights[1].nsColor), "#FFF0A8FF")
        // One that can't be read draws in the old yellow, as it always did.
        XCTAssertNil(HexColor.color(fromHex: highlights[3].color))
        XCTAssertEqual(HexColor.hex(from: highlights[3].nsColor), "#FFFF00FF")
        XCTAssertEqual(HexColor.hex(from: DesignTokens.legacyRenderFallback), "#FFFF00FF")
        // And that fallback is not what new highlights start as.
        XCTAssertNotEqual(MarkupPalette.defaultHighlightHex, "#FFFF00")
    }

    // MARK: Colours stored in documents are never recoloured

    func testStoredHexColoursParseExactlyAsBefore() {
        XCTAssertTrue(HexColor.colorsMatch("#FFFF00", "#FFFF00FF"))
        XCTAssertFalse(HexColor.colorsMatch("#FFFF00", "#FFF0A8"))
        XCTAssertNil(HexColor.color(fromHex: "yellow"))
        let legacy = color("#FFFF00")
        XCTAssertEqual(HexColor.hex(from: legacy), "#FFFF00FF")
    }

    func testPaletteChangesLeaveAPDFAnnotationsColourAlone() throws {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let annotation = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 100, height: 14), forType: .highlight, withProperties: nil)
        annotation.color = color("#FFFF00")
        document.page(at: 0)!.addAnnotation(annotation)

        let defaults = makeDefaults()
        let store = PaletteStore(defaults: defaults)
        defaults.set(encode([("Old", "#FFFF00")]), forKey: "settings.highlightPresets")
        _ = store.effective(.highlight)
        store.resetBackingUp(.highlight)
        store.save(PaletteLayer(hiddenDefaults: MarkupPalette.highlightDefaults.map(\.key)), kind: .highlight)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glossa-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(document.write(to: url))
        let reread = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.annotations.first)
        let c = try XCTUnwrap(reread.color.usingColorSpace(.sRGB))
        XCTAssertEqual(HexColor.hex(from: c).prefix(7), "#FFFF00")
    }

    // MARK: Contrast-aware underlines

    func testContrastRatio() throws {
        XCTAssertEqual(try XCTUnwrap(ColorContrast.ratio(.black, against: white)), 21, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(ColorContrast.ratio(white, against: white)), 1, accuracy: 0.01)
    }

    func testAColourThatAlreadyShowsIsNotDarkenedAgain() {
        for preset in MarkupPalette.underlineDefaults {
            let shown = ColorContrast.readableUnderline(color(preset.hex), on: white, deepening: 0.25)
            XCTAssertEqual(HexColor.hex(from: shown), HexColor.hex(from: color(preset.hex)), preset.hex)
        }
    }

    func testAColourThatWouldNotShowIsDeepenedOnce() throws {
        let pastel = color("#FFF0A8")
        let shown = ColorContrast.readableUnderline(pastel, on: white, deepening: 0.25)
        XCTAssertEqual(HexColor.hex(from: shown), HexColor.hex(from: pastel.blended(withFraction: 0.25, of: .black)!))
        XCTAssertNotEqual(HexColor.hex(from: shown), HexColor.hex(from: pastel))
    }

    func testTheBackgroundDecidesWhetherItShows() throws {
        let sepia = color("#F4ECD8")
        let ochre = color("#B8860B")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(ColorContrast.ratio(ochre, against: sepia)), 1)
        let dark = color("#1C1C1E")
        XCTAssertEqual(HexColor.hex(from: ColorContrast.readableUnderline(ochre, on: dark, deepening: 0.25)), HexColor.hex(from: ochre))
    }

    // MARK: Existing annotations are only ever recoloured by an explicit edit

    func testOnlyTheEditingCodePathsAssignAnAnnotationsColour() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Glossa")
        // New markup, a selected annotation's colour change (and its undo), a comment's colour,
        // and an EPUB highlight's `setColor`. Nothing that reacts to a palette change.
        let expected: [String: Int] = ["AnnotationManager.swift": 3, "CommentManager.swift": 2, "EPUBHighlights.swift": 1]
        var found: [String: Int] = [:]
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/Debug/") {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let count = text.components(separatedBy: "\n").filter {
                $0.contains("annotation.color = ") || $0.contains("highlight.color = ") || $0.contains("items[index].color = ")
            }.count
            if count > 0 { found[url.lastPathComponent] = count }
        }
        XCTAssertEqual(found, expected)
    }

    // MARK: The legacy render fallback is for drawing only

    func testTheLegacyRenderFallbackIsOnlyUsedToDrawStoredHighlights() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Glossa")
        var users: Set<String> = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("legacyRenderFallback") { users.insert(url.lastPathComponent) }
        }
        // The definition, and the two places that draw a stored EPUB highlight.
        XCTAssertEqual(users, ["DesignTokens.swift", "EPUBHighlight.swift", "EPUBPageView+Highlights.swift"])
    }

    // MARK: The old defaults are gone from the code

    func testNoOldDefaultColoursRemainInTheSources() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Glossa")
        // Where an old colour is meant: the lists of earlier versions, and the unreadable-colour fallback.
        let allowed: Set<String> = ["MarkupPalette.swift", "DesignTokens.swift", "ColorWellView.swift"]
        var offenders: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
        for case let url as URL in files where url.pathExtension == "swift" && !url.path.contains("/Debug/") && !allowed.contains(url.lastPathComponent) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            if text.contains("\"#FFFF00\"") || text.contains("\"#000000\"") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertEqual(offenders, [])
    }
}
