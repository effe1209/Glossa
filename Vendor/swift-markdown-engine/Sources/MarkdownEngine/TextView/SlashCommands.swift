//
//  SlashCommands.swift
//  MarkdownEngine
//
//  The "/" command menu: typing "/" at the start of a line (or after a space) lists the
//  commands, typing on narrows them by name, Return or Tab picks one, Esc closes the menu.
//  A pick removes the "/…" it was typed as and applies the command in one undo step.
//

import AppKit

/// One entry of the "/" menu.
struct SlashCommand {
    let title: String
    let symbol: String
    /// Other words that find it ("todo" finds the checklist).
    let keywords: String
    let format: MarkdownFormat

    static let all: [SlashCommand] = [
        SlashCommand(title: "Text", symbol: "textformat", keywords: "paragraph plain normal", format: .paragraph),
        SlashCommand(title: "Heading 1", symbol: "textformat.size.larger", keywords: "h1 title big", format: .heading(level: 1)),
        SlashCommand(title: "Heading 2", symbol: "textformat.size", keywords: "h2 subtitle", format: .heading(level: 2)),
        SlashCommand(title: "Heading 3", symbol: "textformat.size.smaller", keywords: "h3", format: .heading(level: 3)),
        SlashCommand(title: "Bulleted list", symbol: "list.bullet", keywords: "bullet unordered ul", format: .bulletedList),
        SlashCommand(title: "Numbered list", symbol: "list.number", keywords: "ordered ol", format: .numberedList),
        SlashCommand(title: "To-do list", symbol: "checklist", keywords: "checklist task checkbox", format: .checklist),
        SlashCommand(title: "Quote", symbol: "text.quote", keywords: "blockquote citation", format: .quote),
    ] + MarkdownCallout.kinds.map { kind in
        SlashCommand(title: "Callout: \(kind.title)", symbol: kind.symbol, keywords: "callout box admonition \(kind.id)",
                     format: .callout(kind.id))
    } + [
        SlashCommand(title: "Code block", symbol: "curlybraces.square", keywords: "code fence snippet", format: .codeBlock),
        SlashCommand(title: "Table", symbol: "tablecells", keywords: "grid", format: .table),
        SlashCommand(title: "Divider", symbol: "minus", keywords: "rule line separator hr", format: .divider),
        SlashCommand(title: "Inline math", symbol: "function", keywords: "formula latex equation tex", format: .inlineMath),
        SlashCommand(title: "Display math", symbol: "sum", keywords: "formula latex equation block tex", format: .displayMath),
    ]

    /// The commands `query` finds: every word of it starts a word of the title or the keywords.
    /// Titles that start with the query come first. An empty query finds all of them.
    static func matches(for query: String) -> [SlashCommand] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return all }
        let found = all.filter { command in
            let haystack = (command.title + " " + command.keywords).lowercased().split(whereSeparator: { " :".contains($0) })
            return words.allSatisfy { word in haystack.contains { $0.hasPrefix(word) } }
        }
        let lowered = query.lowercased()
        return found.filter { $0.title.lowercased().hasPrefix(lowered) } + found.filter { !$0.title.lowercased().hasPrefix(lowered) }
    }
}

/// The menu: opened by typing "/", driven by the text view's own keys.
@MainActor
final class SlashMenuController {
    private weak var coordinator: NativeTextViewCoordinator?
    private var panel: NSPanel?
    private let list = SlashMenuListView()
    private(set) var slashLocation: Int?
    private var matches: [SlashCommand] = []

    init(coordinator: NativeTextViewCoordinator) {
        self.coordinator = coordinator
        list.onChoose = { [weak self] index in self?.choose(index) }
    }

    var isActive: Bool { slashLocation != nil }
    /// The menu is up, with something to pick.
    private var isShowing: Bool { panel?.isVisible == true }

    // MARK: Opening and following the text

    /// Called after a "/" was typed: opens the menu when it starts a line or follows a space.
    func slashTyped() {
        guard let tv = coordinator?.textView, !tv.hasMarkedText(), tv.selectedRange().length == 0 else { return }
        let text = tv.string as NSString
        let caret = tv.selectedRange().location
        guard caret >= 1, text.character(at: caret - 1) == 0x2F else { return }
        if caret >= 2 {
            let before = text.character(at: caret - 2)
            guard before == 0x0A || before == 0x20 || before == 0x09 else { return }
        }
        guard coordinator?.tableEditingSession.isActive != true else { return }
        slashLocation = caret - 1
        refresh()
    }

    /// The text changed: narrow the list to what is typed after the "/", or close the menu if it no longer applies.
    func textChanged() {
        guard isActive else { return }
        refresh()
    }

    func selectionChanged() {
        guard isActive, let tv = coordinator?.textView, let slash = slashLocation else { return }
        let caret = tv.selectedRange().location
        if tv.selectedRange().length > 0 || caret <= slash { dismiss() }
    }

    private func refresh() {
        guard let tv = coordinator?.textView, let slash = slashLocation else { return dismiss() }
        let text = tv.string as NSString
        let caret = tv.selectedRange().location
        guard slash < text.length, text.character(at: slash) == 0x2F, caret > slash, tv.selectedRange().length == 0 else {
            return dismiss()
        }
        let query = text.substring(with: NSRange(location: slash + 1, length: caret - slash - 1))
        // A line break, or a long run that finds nothing, ends it: the "/" was just a character.
        if query.contains("\n") || (query.count > 24) { return dismiss() }
        matches = SlashCommand.matches(for: query)
        guard !matches.isEmpty else { hidePanel(); return }
        list.update(titles: matches.map { ($0.title, $0.symbol) })
        showPanel(for: tv, caret: caret)
    }

    // MARK: Keys

    /// The text view's command selectors while the menu is up. True when the menu took the key.
    func handle(_ selector: Selector) -> Bool {
        guard isActive, isShowing else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): list.move(by: 1); return true
        case #selector(NSResponder.moveUp(_:)): list.move(by: -1); return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): choose(list.selected); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }

    // MARK: Picking

    private func choose(_ index: Int) {
        guard matches.indices.contains(index), let slash = slashLocation, let coordinator, let tv = coordinator.textView else { return dismiss() }
        let command = matches[index]
        let caret = tv.selectedRange().location
        dismiss()
        // The "/…" goes and the command applies as one undo step.
        let undo = tv.undoManager
        undo?.beginUndoGrouping()
        defer { undo?.endUndoGrouping() }
        MarkdownLists.performEdit(tv, replace: NSRange(location: slash, length: max(0, caret - slash)), with: "")
        tv.setSelectedRange(NSRange(location: slash, length: 0))
        coordinator.apply(command.format)
    }

    func dismiss() {
        slashLocation = nil
        matches = []
        hidePanel()
    }

    // MARK: The panel

    private func hidePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func showPanel(for tv: NSTextView, caret: Int) {
        guard let window = tv.window else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let size = list.fittingSize
        panel.setContentSize(size)
        let anchor = tv.firstRect(forCharacterRange: NSRange(location: max(0, caret - 1), length: 1), actualRange: nil)
        var origin = NSPoint(x: anchor.minX, y: anchor.minY - size.height - 6)
        if let screen = window.screen ?? NSScreen.main {
            // Above the line when there's no room below; inside the screen sideways.
            if origin.y < screen.visibleFrame.minY { origin.y = anchor.maxY + 6 }
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
        }
        panel.setFrameOrigin(origin)
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.contentView = list
        return panel
    }
}

/// The list inside the panel: a symbol and a title a row, the chosen row marked, nine rows at most before it scrolls.
final class SlashMenuListView: NSView {
    var onChoose: (Int) -> Void = { _ in }
    private(set) var selected = 0
    private var rows: [(title: String, symbol: String)] = []
    private var firstVisible = 0

    private let rowHeight: CGFloat = 30
    private let visibleRows = 9
    private let width: CGFloat = 270
    private let inset: CGFloat = 6

    override var isFlipped: Bool { true }

    func update(titles: [(String, String)]) {
        rows = titles.map { (title: $0.0, symbol: $0.1) }
        selected = 0
        firstVisible = 0
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selected = (selected + delta + rows.count) % rows.count
        if selected < firstVisible { firstVisible = selected }
        if selected >= firstVisible + visibleRows { firstVisible = selected - visibleRows + 1 }
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width, height: CGFloat(min(rows.count, visibleRows)) * rowHeight + inset * 2)
    }

    override var fittingSize: NSSize { intrinsicContentSize }

    override func draw(_ dirtyRect: NSRect) {
        let dark = ChromePalette.isDark(effectiveAppearance)
        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        ChromePalette.surface.setFill()
        body.fill()
        ChromePalette.border.setStroke()
        body.lineWidth = 1
        body.stroke()
        _ = dark

        let visible = rows.indices.filter { $0 >= firstVisible && $0 < firstVisible + visibleRows }
        for index in visible {
            let frame = NSRect(x: inset, y: inset + CGFloat(index - firstVisible) * rowHeight, width: bounds.width - inset * 2, height: rowHeight)
            if index == selected {
                ChromePalette.hover.setFill()
                NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            }
            SelectionBarButton.drawSymbol(rows[index].symbol, size: 16, in: NSRect(x: frame.minX + 8, y: frame.midY - 8, width: 16, height: 16),
                                          color: ChromePalette.secondaryText)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ChromePalette.text]
            let size = (rows[index].title as NSString).size(withAttributes: attributes)
            (rows[index].title as NSString).draw(at: NSPoint(x: frame.minX + 8 + 16 + 8, y: frame.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func row(at point: NSPoint) -> Int? {
        let index = firstVisible + Int((point.y - inset) / rowHeight)
        return point.y >= inset && rows.indices.contains(index) ? index : nil
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)), index != selected { selected = index; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)) { onChoose(index) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
