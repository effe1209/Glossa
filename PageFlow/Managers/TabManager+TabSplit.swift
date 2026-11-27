//
//  TabManager+TabSplit.swift
//  PageFlow
//
//  Two tabs side by side in one window, typically a PDF and the note that
//  quotes it. The active tab is one of the two; clicking the other pane makes
//  it active (the panes' own click-to-focus), and choosing a third tab from
//  the tab bar takes the place of the pane that was active. Each pane keeps
//  its own content, sidebars, find and zoom; the window's toolbar follows the
//  active one.
//

import Foundation
import PDFKit
import AppKit

extension TabManager {
    enum SplitSide { case leading, trailing }

    /// The two tabs on screen, or nil when the window shows one: a pair needs both
    /// tabs to exist and the active tab to be one of them.
    var splitView: (leading: UUID, trailing: UUID)? {
        guard let active = activeTabID else { return nil }
        return splitGroup(containing: active)
    }

    /// The pair showing now: the one the active tab is in.
    var splitPair: [UUID] {
        guard let split = splitView else { return [] }
        return [split.leading, split.trailing]
    }

    var isTabSplit: Bool { splitView != nil }

    /// The left pane's share of the width, kept for each pair on its own (under its left
    /// tab) and for the chooser while one is open.
    var splitFraction: CGFloat {
        get { splitFractionKey.flatMap { splitFractions[$0] } ?? 0.5 }
        set { if let key = splitFractionKey { splitFractions[key] = newValue } }
    }

    private var splitFractionKey: UUID? {
        splitView?.leading ?? (isChoosingSplitPartner ? splitChooserAnchor : nil)
    }

    /// The joined pairs in the tab strip: they stay while another tab is open on its own,
    /// and either half brings its two back side by side.
    var splitGroups: [(leading: UUID, trailing: UUID)] {
        splitPairs.compactMap { pair in
            guard pair.count == 2, pair[0] != pair[1],
                  pair.allSatisfy({ id in tabs.contains { $0.id == id } }) else { return nil }
            return (pair[0], pair[1])
        }
    }

    func splitGroup(containing tabID: UUID) -> (leading: UUID, trailing: UUID)? {
        splitGroups.first { $0.leading == tabID || $0.trailing == tabID }
    }

    func splitSide(of tabID: UUID) -> SplitSide? {
        guard let split = splitView else { return nil }
        return tabID == split.leading ? .leading : tabID == split.trailing ? .trailing : nil
    }

    /// The pair to show for `active`: the most recently used other tab, preferring one of
    /// the other kind (a PDF with its note); a PDF goes on the left, the note on the right.
    static func splitPair(active: UUID, recency: [UUID], tabs: [UUID], isPDF: (UUID) -> Bool) -> [UUID]? {
        let others = recency.filter { $0 != active && tabs.contains($0) } + tabs.filter { $0 != active && !recency.contains($0) }
        guard let partner = others.first(where: { isPDF($0) != isPDF(active) }) ?? others.first else { return nil }
        return isPDF(partner) && !isPDF(active) ? [partner, active] : [active, partner]
    }

    /// The window's "two tabs side by side" switch: it opens the other half as a chooser,
    /// where the reader picks an open tab, opens a file, starts a note or drops a file.
    func toggleTabSplit() {
        if isTabSplit { closeTabSplit(); return }
        if isChoosingSplitPartner { cancelSplitChooser(); return }
        guard let active = activeTabID else { return }
        splitChooserAnchor = active
        splitAwaitsPartner = false
        splitFraction = 0.5
    }

    /// The other half is showing its chooser beside the active tab.
    var isChoosingSplitPartner: Bool {
        guard let anchor = splitChooserAnchor, anchor == activeTabID, tabs.contains(where: { $0.id == anchor }) else { return false }
        return true
    }

    /// Which half a tab fills: its side of the pair, or the left of a chooser's window.
    func paneSide(of tabID: UUID) -> SplitSide? {
        if let side = splitSide(of: tabID) { return side }
        return isChoosingSplitPartner && tabID == splitChooserAnchor ? .leading : nil
    }

    func cancelSplitChooser() {
        splitChooserAnchor = nil
        splitAwaitsPartner = false
    }

    /// The other open tabs, the most recently used first: what the chooser offers.
    var splitChooserTabs: [TabModel] {
        let order = tabRecency.order
        return tabs.filter { $0.id != splitChooserAnchor }.sorted {
            (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
        }
    }

    func chooseSplitPartner(_ id: UUID) {
        guard let anchor = splitChooserAnchor else { return }
        cancelSplitChooser()
        showSplit(active: anchor, partner: id)
    }

    /// Starts waiting for whatever the chooser is about to open; gives up if nothing
    /// has opened a while later, so a failed open cannot claim a later tab click.
    private func awaitSplitPartner() {
        splitAwaitsPartner = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.splitAwaitsPartner = false
        }
    }

    func splitOpenFile() {
        awaitSplitPartner()
        openFilePicker(onCancel: { [weak self] in self?.splitAwaitsPartner = false })
    }

    func splitNewMarkdown() {
        awaitSplitPartner()
        newMarkdownDocument()
    }

    func splitOpenRecent(_ recent: RecentFile, from recents: RecentFilesManager) {
        awaitSplitPartner()
        openRecentFile(recent, from: recents)
    }

    func splitOpenDropped(_ urls: [URL]) {
        awaitSplitPartner()
        openDroppedFiles(urls)
    }

    /// Shows `partner` beside `active`: a PDF goes on the left, a note on the right.
    func showSplit(active: UUID, partner: UUID) {
        let partnerIsPDF = sessions[partner]?.pdfManager != nil
        let activeIsPDF = sessions[active]?.pdfManager != nil
        // A tab is in one pair: choosing it here takes it out of any other.
        splitPairs.removeAll { $0.contains(active) || $0.contains(partner) }
        splitPairs.append(partnerIsPDF && !activeIsPDF ? [partner, active] : [active, partner])
        splitFraction = 0.5
        warmSplitPanes()
        fitSplitPDFPanes(totalWidth: NSApp.keyWindow?.contentView?.bounds.width ?? 0)
    }

    /// A note pane narrower than this is fitted to its width.
    static let noteFitThreshold: CGFloat = 820

    /// A PDF pane narrower than its page shrinks the page to fit the width, rather than
    /// being cut off; it then stays fitted as the pane is resized.
    func fitSplitPDFPanes(totalWidth: CGFloat) {
        guard totalWidth > 0 else { return }
        let leadingWidth = (totalWidth * splitFraction).rounded()
        var panes: [(UUID, CGFloat)] = []
        if let split = splitView {
            panes = [(split.leading, leadingWidth), (split.trailing, totalWidth - leadingWidth)]
        } else if isChoosingSplitPartner, let anchor = splitChooserAnchor {
            panes = [(anchor, leadingWidth)]
        }
        for (id, width) in panes {
            // A note narrower than its reading column is scaled to fit, not cut off.
            if let note = sessions[id]?.content.markdown {
                if width < Self.noteFitThreshold, !note.isWidthFitted { note.zoomToFit() }
                continue
            }
            guard let pdf = sessions[id]?.pdfManager, pdf.hasDocument, !pdf.isAutoScaling, pdf.activeFitMode == nil,
                  let page = pdf.currentPage else { continue }
            let pageWidth = page.bounds(for: .cropBox).width * pdf.scaleFactor
            if pageWidth + 24 > width { pdf.fit(.width) }
        }
    }

    /// Separates the pair showing now into two tabs again; other pairs stay.
    func closeTabSplit() {
        guard let active = activeTabID else { return }
        splitPairs.removeAll { $0.contains(active) }
    }

    /// A tab chosen from outside the pair opens on its own and the pair waits in the strip;
    /// with no tab left active the pair is gone.
    func followActiveTabInSplit(from previous: UUID?) {
        if activeTabID == nil { splitPairs = [] }
        guard let anchor = splitChooserAnchor else { return }
        guard let active = activeTabID, active != anchor else { return }
        // What the chooser opened comes to the front and becomes the second pane; any other
        // tab chosen meanwhile just leaves the chooser.
        let opened = splitAwaitsPartner
        cancelSplitChooser()
        if opened { showSplit(active: anchor, partner: active) }
    }
}
