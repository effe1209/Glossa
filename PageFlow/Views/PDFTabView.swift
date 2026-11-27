//
//  PDFTabView.swift
//  PageFlow
//
//  The view a `.pdf` tab mounts — the PDF branch of `TabRender`, peer of
//  `MarkdownTabView`. Mounted through `TabRenderView`. (Formerly `MainView`.)
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct PDFTabView: View {
    let tabID: UUID
    @Bindable var pdfManager: PDFManager
    var searchManager: SearchManager
    @Bindable var annotationManager: AnnotationManager
    @Bindable var commentManager: CommentManager
    @Bindable var bookmarkManager: BookmarkManager
    var tabUndoManager: UndoManager
    var isActive: Bool
    var isDisplayed: Bool = true
    @Binding var showingSearch: Bool
    let searchFocusRequest: Int
    @Bindable var tabManager: TabManager
    var onRequestFocus: () -> Void = {}

    @State private var settingsManager = SettingsManager.shared
    /// The Find bar's width while it shows; the page chip stays clear of it.
    /// The sidebar is sliding in at the pointer, not held open.
    @State private var isPeekingSidebar = false
    /// The rail's availability as it was when the split divider was picked up.
    @State private var frozenRailAvailability: Bool?
    @State private var sidebarPeekEnd: Task<Void, Never>?
    @State private var findBarWidth: CGFloat = 0

    private var showingGoToPage: Bool {
        get { tabManager.showingGoToPage(for: tabID) }
        nonmutating set { tabManager.setShowingGoToPage(newValue, for: tabID) }
    }

    private var showingGoToPageBinding: Binding<Bool> {
        Binding(
            // Gated on isActive like the sidebars and search bar: a hidden warm
            // tab's window-modal sheet would strand over the visible tab and
            // navigate the wrong document.
            get: { isActive && tabManager.showingGoToPage(for: tabID) },
            set: { tabManager.setShowingGoToPage($0, for: tabID) }
        )
    }

    private var showingOutline: Bool {
        get { tabManager.showingOutline(for: tabID) }
        nonmutating set { tabManager.setShowingOutline(newValue, for: tabID) }
    }

    private var showingComments: Bool {
        get { tabManager.showingComments(for: tabID) }
        nonmutating set { tabManager.setShowingComments(newValue, for: tabID) }
    }

    private var isEditingPages: Bool {
        get { tabManager.isEditingPages(for: tabID) }
        nonmutating set { tabManager.setIsEditingPages(newValue, for: tabID) }
    }

    private var isEditingPagesBinding: Binding<Bool> {
        Binding(
            get: { tabManager.isEditingPages(for: tabID) },
            set: { tabManager.setIsEditingPages($0, for: tabID) }
        )
    }

    private var topChromeHeight: CGFloat {
        TopChromeView.height(toolbarScale: settingsManager.toolbarScale)
    }

    var body: some View {
        ZStack {
            if pdfManager.hasDocument {
                PDFViewWrapper(
                    pdfManager: pdfManager,
                    searchManager: searchManager,
                    annotationManager: annotationManager,
                    commentManager: commentManager,
                    bookmarkManager: bookmarkManager,
                    tabUndoManager: tabUndoManager,
                    isActive: isActive,
                    isDisplayed: isDisplayed,
                    takesKeyboard: FindOverlay.documentTakesKeyboard(isShown: isActive && isDisplayed, findIsOpen: showingSearch),
                    onRequestFocus: onRequestFocus,
                    quoteHost: tabManager
                )
            } else {
                emptyState
            }
        }
        .ignoresSafeArea(.all, edges: .all)
        .task(id: pdfManager.documentURL) { await tabManager.refreshCitingNotes(for: tabID, pdf: pdfManager) }
        .onChange(of: tabManager.isResizingSplit) { _, resizing in
            frozenRailAvailability = resizing ? liveRailAvailability : nil
            if resizing, isPeekingSidebar {
                sidebarPeekEnd?.cancel()
                isPeekingSidebar = false
            }
        }
        .onChange(of: showingComments) { _, shown in
            if shown { Task { await tabManager.refreshCitingNotes(for: tabID, pdf: pdfManager) } }
        }
        .overlay {
            if isActive, isDisplayed {
                PDFNavigationRail(pdfManager: pdfManager, bookmarkManager: bookmarkManager,
                    eligible: railIsAvailable,
                    topInset: topChromeHeight, onShowSidebar: { showSidebarFromRail() },
                    // The rail is the closed sidebar: reaching it opens the
                    // sidebar beside it, ready to pin.
                    onPointerEnteredLane: { beginSidebarPeek(keepingOpen: true) },
                    isSidebarOpen: showingOutline || isPeekingSidebar,
                    pageRects: pdfManager.navigationRailPageRects)
            }
        }
        .overlay(alignment: .topTrailing) {
            commentsSidebarOverlay
        }
        .overlay(alignment: .topLeading) {
            outlineSidebarOverlay
        }
        .overlay(alignment: .bottom) {
            // isActive gate: keeps inactive warm tabs' hover tracking areas out
            // of the window (same gate as the sidebars).
            if isActive, pdfManager.hasDocument {
                bottomPageBar
            }
        }
        .overlay(alignment: .bottom) {
            FindOverlay(
                driver: pdfFindDriver,
                isActive: isActive,
                showingSearch: $showingSearch,
                focusRequest: searchFocusRequest,
                onBarWidthChange: { findBarWidth = $0 }
            )
        }
        .pageFlowFileDropTarget(tabManager: tabManager)
        .sheet(isPresented: showingGoToPageBinding) {
            goToPageDialog
        }
        .ignoresSafeArea(.all, edges: .all)
        .onChange(of: pdfManager.hasDocument) { _, hasDoc in
            if !hasDoc {
                showingOutline = false
                showingComments = false
                bookmarkManager.clearBookmarks()
            }
        }
        .onChange(of: pdfManager.documentURL) { _, newURL in
            bookmarkManager.loadBookmarks(for: newURL)
        }
        .onChange(of: commentManager.selectedCommentID) { _, newValue in
            if newValue != nil {
                withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                    showingComments = true
                }
            }
        }
    }

    private var commentsSidebarOverlay: some View {
        ZStack(alignment: .topTrailing) {
            // Only the active warm tab mounts its sidebar: an inactive tab's
            // invisible copy keeps AppKit machinery alive (ClickCatcher's click
            // recognizers, the comment text editor) that competes with the
            // active tab's sidebar for clicks and focus — same class of bug as
            // the SearchBar focus gate below.
            if isActive, showingComments, pdfManager.hasDocument {
                CommentsSidebar(
                    commentManager: commentManager,
                    section: Binding(
                        get: { tabManager.commentsSection(for: tabID) },
                        set: { tabManager.setCommentsSection($0, for: tabID) }
                    ),
                    notes: tabManager.citingNotes(for: tabID),
                    onOpenNote: { tabManager.openCitingNote($0) },
                    onClose: { showingComments = false }
                )
                .onExitCommand { showingComments = false }
                .padding(.top, topChromeHeight + DesignTokens.spacingXS)
                .padding(.bottom, DesignTokens.spacingMD)
                .padding(.trailing, DesignTokens.spacingXS)
                .pageFlowPanelTransition(edge: .trailing)
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingComments)
    }

    /// The rail can show: enabled, and the document fits beside it.
    private var railIsAvailable: Bool {
        frozenRailAvailability ?? liveRailAvailability
    }

    private var liveRailAvailability: Bool {
        settingsManager.showNavigationRail && !pdfManager.suppressesNavigationRail && pdfManager.navigationRailFitsViewport
    }

    /// Slides the sidebar in while the pointer is at the left edge.
    private func beginSidebarPeek(keepingOpen: Bool = false) {
        guard !showingOutline else { return }
        if isPeekingSidebar {
            // Still on the rail: the peek stays.
            if keepingOpen { scheduleSidebarPeekEnd(after: .milliseconds(1500)) }
            return
        }
        // A document with no outline opens on its pages, not an empty list.
        if tabManager.pdfSidebarMode(for: tabID) == .outline, pdfManager.outlineItems().isEmpty {
            tabManager.setPDFSidebarMode(.thumbnails, for: tabID)
        }
        isPeekingSidebar = true
        scheduleSidebarPeekEnd(after: .milliseconds(900))
    }

    /// Ends a peek unless the pointer has reached the panel meanwhile.
    private func scheduleSidebarPeekEnd(after delay: Duration) {
        sidebarPeekEnd?.cancel()
        sidebarPeekEnd = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isPeekingSidebar = false
            isEditingPages = false
        }
    }

    /// A click on the rail pins the sidebar on the pages: thumbnails, whatever
    /// it showed before.
    private func showSidebarFromRail() {
        tabManager.setPDFSidebarMode(.thumbnails, for: tabID)
        setSidebarPinned(true)
    }

    private func setSidebarPinned(_ pinned: Bool) {
        sidebarPeekEnd?.cancel()
        isPeekingSidebar = false
        if !pinned { isEditingPages = false }
        showingOutline = pinned
    }

    private var outlineSidebarOverlay: some View {
        ZStack(alignment: .topLeading) {
            // A thin strip on the left edge: reaching it peeks the sidebar in.
            // Only without a rail, which is the doorway otherwise.
            if isActive, pdfManager.hasDocument, !showingOutline, !railIsAvailable, !tabManager.isResizingSplit {
                Color.clear
                    // Clear of the split divider, which straddles this pane's edge.
                    .frame(width: 28)
                    .padding(.leading, tabManager.splitSide(of: tabID) == .trailing ? 8 : 0)
                    .frame(maxHeight: .infinity)
                    .padding(.top, topChromeHeight)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { beginSidebarPeek() } }
            }
            // Same gate as the comments sidebar: the thumbnail grid's AppKit
            // reporters and drag machinery must not stay mounted in inactive
            // warm tabs.
            if isActive, showingOutline || isPeekingSidebar, pdfManager.hasDocument {
                SidebarView(
                    pdfManager: pdfManager,
                    bookmarkManager: bookmarkManager,
                    isEditingPages: isEditingPagesBinding,
                    mode: Binding(
                        get: { tabManager.pdfSidebarMode(for: tabID) },
                        set: { tabManager.setPDFSidebarMode($0, for: tabID) }
                    ),
                    items: pdfManager.outlineItems(),
                    onClose: { setSidebarPinned(false) },
                    pin: SidebarPin(isPinned: showingOutline, toggle: { setSidebarPinned(!showingOutline) })
                )
                .onHover { inside in
                    guard isPeekingSidebar else { return }
                    if inside { sidebarPeekEnd?.cancel() } else { scheduleSidebarPeekEnd(after: .milliseconds(350)) }
                }
                .onExitCommand {
                    isEditingPages = false
                    setSidebarPinned(false)
                }
                .padding(.top, topChromeHeight + DesignTokens.spacingXS)
                .padding(.bottom, DesignTokens.spacingMD)
                // Beside the rail's lane, which stays where it is.
                .padding(.leading, railIsAvailable ? NavigationRailView.laneWidth + DesignTokens.spacingXS : DesignTokens.spacingXS)
                .pageFlowPanelTransition(edge: .leading)
            }
        }
        .animation(.easeInOut(duration: DesignTokens.animationFast), value: showingOutline || isPeekingSidebar)
    }

    /// The PDF Find backend as a `FindDriving`. A fresh value each `body` (no
    /// observable-state mutation to build it); it resolves the document and pushes
    /// nav state internally, so PDF find behaves exactly as the old inline bar did.
    /// The PDF search path itself is byte-identical.
    private var pdfFindDriver: PDFFindDriver {
        PDFFindDriver(searchManager: searchManager, pdfManager: pdfManager)
    }

    // MARK: - Empty State

    /// The window's blank-tab state — content-NEUTRAL: an empty tab can become
    /// a PDF or a Markdown document (the picker and the drop target both accept
    /// both), and it can start a fresh Markdown document in place (⌘⇧N's action).
    private var emptyState: some View {
        VStack(spacing: DesignTokens.spacingLG) {
            Image(systemName: "doc.text")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)

            Text("No Document Open")
                .font(.title2)
                .foregroundStyle(.secondary)

            HStack(spacing: DesignTokens.spacingMD) {
                Button("Open Document") {
                    tabManager.openFilePicker()
                }
                .buttonStyle(.plain)
                .pageFlowClickCursor()
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.vertical, DesignTokens.spacingSM)
                .pageFlowLiquidGlassPanel(.primaryButton)

                Button("New Markdown") {
                    tabManager.newMarkdownDocument()
                }
                .buttonStyle(.plain)
                .pageFlowClickCursor()
                .padding(.horizontal, DesignTokens.spacingMD)
                .padding(.vertical, DesignTokens.spacingSM)
                .pageFlowLiquidGlassPanel(.primaryButton)
            }

            Text("or drag and drop a PDF, EPUB or Markdown file here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Page Indicator

    private var bottomPageBar: some View {
        PDFPageStatusBar(
            pdfManager: pdfManager,
            centerReservation: FindOverlay.chipReservation(barWidth: findBarWidth),
            height: topChromeHeight
        ) {
            showingGoToPage = true
        }
    }

    // MARK: - Go To Page Dialog

    private var goToPageDialog: some View {
        GoToDialog(
            title: "Go to Page",
            prompt: "Page number",
            onSubmit: { page in
                guard page > 0, page <= pdfManager.pageCount else {
                    return "Page must be between 1 and \(pdfManager.pageCount)."
                }
                pdfManager.jump(toPage: page - 1)
                return nil
            },
            isPresented: showingGoToPageBinding
        )
    }
}

// MARK: - Page Status Bar

/// The page and zoom chip. A view of its own so that the page number and the zoom,
/// which change as the reader scrolls and zooms, invalidate only this chip: read in
/// `PDFTabView.body` they re-rendered the whole tab (the PDF view's representable and
/// every overlay) on each page crossed during a fast scroll.
private struct PDFPageStatusBar: View {
    let pdfManager: PDFManager
    let centerReservation: CGFloat
    let height: CGFloat
    let onGoToPage: () -> Void

    var body: some View {
        let page = pdfManager.currentPageIndex + 1
        let count = pdfManager.pageCount
        let zoom = "\(PDFZoomFit.percentage(of: pdfManager.scaleFactor))%"
        DocumentStatusBar(
            label: "Page \(page) of \(count) · \(zoom)",
            shorterLabels: ["\(page) / \(count) · \(zoom)", "\(page) / \(count)"],
            centerReservation: centerReservation,
            help: "Go to page",
            height: height,
            action: onGoToPage
        )
    }
}

// MARK: - Window Title Updater

/// Sets NSWindow.title for Dock menu display (title bar remains hidden)
struct WindowTitleUpdater: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> WindowTitleView {
        let view = WindowTitleView()
        view.title = title
        return view
    }

    func updateNSView(_ nsView: WindowTitleView, context: Context) {
        nsView.title = title
    }
}

final class WindowTitleView: NSView {
    var title = "" {
        didSet {
            updateTitleIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTitleIfNeeded()
    }

    private func updateTitleIfNeeded() {
        guard let window, window.title != title else { return }
        window.title = title
    }
}

// MARK: - Drop Helpers

extension NSItemProvider {
    /// Resolves a dropped file URL, handling the `Data` / `URL` / `NSURL`
    /// representations AppKit may deliver. Returns nil if the item is not a file URL.
    /// Shared by the content-agnostic `FileDropTarget`.
    func loadDroppedFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                switch item {
                case let data as Data: url = URL(dataRepresentation: data, relativeTo: nil)
                case let value as URL: url = value
                case let value as NSURL: url = value as URL
                default: url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }
}

#Preview {
    PDFTabView(
        tabID: UUID(),
        pdfManager: PDFManager(),
        searchManager: SearchManager(),
        annotationManager: AnnotationManager(),
        commentManager: CommentManager(),
        bookmarkManager: BookmarkManager(),
        tabUndoManager: UndoManager(),
        isActive: true,
        showingSearch: .constant(false),
        searchFocusRequest: 0,
        tabManager: TabManager()
    )
}
