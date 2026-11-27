//
//  TabContainerView.swift
//  PageFlow
//
//  Root container view for tab management. Each window owns its own TabManager.
//

import SwiftUI
import AppKit

struct TabContainerView: View {
    @Environment(RecentFilesManager.self) private var recentFilesManager
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var settingsManager = SettingsManager.shared

    /// Holds this window's `TabManager`, constructed lazily on first use.
    ///
    /// SwiftUI re-runs a view's `init` on every scene/body recomputation. With
    /// `State(wrappedValue: TabManager())` that built — then immediately threw
    /// away — a full `TabManager` (five managers + wiring) on each of those
    /// passes; with a second scene open that invalidates often, it churned
    /// hundreds of throwaway managers and dominated frame time. The holder defers
    /// construction to first access, so a re-init costs nothing.
    @State private var holder: TabManagerHolder

    /// Default init: each window lazily creates its own TabManager.
    init() {
        self._holder = State(wrappedValue: TabManagerHolder())
    }

    /// Tear-off init: the caller hands us a pre-populated TabManager (e.g.
    /// one that already contains the dragged-out tab). The window opens with
    /// that state already in place — no race, no placeholder dance.
    init(tabManager: TabManager) {
        self._holder = State(wrappedValue: TabManagerHolder(adopting: tabManager))
    }

    /// This window's TabManager, stable for the view's lifetime.
    private var tabManager: TabManager { holder.manager }

    /// The drop indicator follows the active document's requested chrome palette;
    /// PDF and unforced Markdown retain the Mac's appearance.
    private var dropIndicatorColorScheme: ColorScheme {
        if let epub = tabManager.activeSession?.content.epub {
            return epub.requestedPalette == .dark ? .dark : .light
        }
        guard let id = tabManager.activeTabID, tabManager.contentKind(for: id) == .markdown else {
            return systemColorScheme
        }
        return settingsManager.markdownColorScheme.forcedColorScheme ?? systemColorScheme
    }

    private func showingSearch(for tabID: UUID) -> Binding<Bool> {
        Binding(get: { tabManager.showingSearch(for: tabID) }, set: { tabManager.setShowingSearch($0, for: tabID) })
    }

    private var activeWindowTitle: String {
        tabManager.activeSession?.content.document.documentTitle ?? "Glossa"
    }

    /// One warm tab in the ZStack: the active tab is visible, hit-testable and
    /// on top; the rest stay mounted, hidden at full size (the editor inside is
    /// hidden at the AppKit level and does no work), so switching back is an
    /// instant show. `.id(tabID)` keeps each tab's PDFViewWrapper Coordinator
    /// bound to that tab's managers.
    @ViewBuilder
    private func warmTab(for render: TabRender, in size: CGSize) -> some View {
        let isActiveTab = render.id == tabManager.activeTabID
        let side = tabManager.paneSide(of: render.id)
        let isDisplayed = tabManager.isTabSplit || tabManager.isChoosingSplitPartner ? side != nil : isActiveTab
        let leadingWidth = (size.width * tabManager.splitFraction).rounded()
        let width: CGFloat = switch side {
        case .leading: leadingWidth
        case .trailing: size.width - leadingWidth
        case nil: size.width
        }
        TabRenderView(
            render: render,
            isActive: isActiveTab,
            isDisplayed: isDisplayed,
            showingSearch: showingSearch(for: render.id),
            searchFocusRequest: tabManager.searchFocusRequest,
            tabManager: tabManager
        )
        .id(render.id)
        .frame(width: width, height: size.height)
        // A pane draws and takes clicks only inside its own half: the PDF's backdrop
        // reaches past its frame and, painted above the note, left it black and dead.
        .clipped()
        .offset(x: side == .trailing ? leadingWidth : 0)
        .opacity(isDisplayed ? 1 : 0)
        .allowsHitTesting(isDisplayed)
        .zIndex(isDisplayed ? 1 : 0)
        .accessibilityHidden(!isDisplayed)
    }

    /// The handle between two panes: drag to give one more room.
    private func splitHandle(in size: CGSize) -> some View {
        let x = (size.width * tabManager.splitFraction).rounded()
        return SplitDividerHandle(
            totalWidth: size.width,
            fraction: tabManager.splitFraction,
            onChange: {
                tabManager.splitFraction = min(0.75, max(0.25, $0))
                tabManager.fitSplitPDFPanes(totalWidth: size.width)
            },
            onReset: {
                tabManager.splitFraction = 0.5
                tabManager.fitSplitPDFPanes(totalWidth: size.width)
            },
            onDragState: { tabManager.isResizingSplit = $0 }
        )
        .frame(width: SplitDividerHandle.hitWidth, height: size.height)
        .offset(x: x - SplitDividerHandle.hitWidth / 2)
        .zIndex(2)
        .accessibilityLabel("Resize panes")
    }

    /// Every warm tab (TabManager.renderedTabs, LRU-capped) in one ZStack, so
    /// ⌘-number / ⌘[ ⌘] switching is an instant show rather than a teardown +
    /// cold rebuild. Only the active tab keeps its window-wide event monitors
    /// installed (driven by `isActive`); the LRU cap frees least-recently-used
    /// tabs. Per-tab reading position is restored by TabManager.restoreTabState
    /// + DocumentStateStore.
    private var content: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(tabManager.renderedTabs) { render in
                    warmTab(for: render, in: proxy.size)
                }
                if tabManager.isChoosingSplitPartner {
                    let leadingWidth = (proxy.size.width * tabManager.splitFraction).rounded()
                    SplitPartnerChooserView(tabManager: tabManager, topInset: TopChromeView.height(toolbarScale: settingsManager.toolbarScale))
                        .frame(width: proxy.size.width - leadingWidth, height: proxy.size.height)
                        .offset(x: leadingWidth)
                        .zIndex(1)
                }
                if tabManager.isTabSplit || tabManager.isChoosingSplitPartner { splitHandle(in: proxy.size) }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .coordinateSpace(name: "tabPanes")
        }
    }

    var body: some View {
        content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.all, edges: .all)
        .overlay(alignment: .top) {
            TopChromeView(tabManager: tabManager)
                .ignoresSafeArea(.all, edges: .top)
        }
        // The ONE transient pill for this window ("Saved", open failures) —
        // content-agnostic, mounted once so PDF and Markdown can't drift.
        .overlay(alignment: .bottom) {
            TransientToastOverlay(tabManager: tabManager)
        }
        // The ONE file-drop indicator for this window, around the whole window
        // and above the chrome, in the active document's light or dark.
        .overlay {
            FileDropOverlay(isVisible: tabManager.isFileDropHovering)
                .environment(\.colorScheme, dropIndicatorColorScheme)
        }
        .toolbar(.hidden)
        .background(WindowConfigurator(isAlwaysOnTop: tabManager.isAlwaysOnTop))
        .background(WindowTitleUpdater(title: activeWindowTitle))
        .background(WindowRegistrar(tabManager: tabManager))
        .focusedSceneValue(\.tabManagerReference, FocusedTabManagerReference(manager: tabManager))
        .onAppear {
            tabManager.documentOpenedHandler = { [recentFilesManager] url, isSecurityScoped in
                recentFilesManager.addRecentFile(url, isSecurityScoped: isSecurityScoped)
            }

            // Deliver immediately if already registered. Otherwise keep launch
            // URLs queued for WindowRegistrar so restore can deduplicate them.
            if let appDelegate = AppDelegate.shared {
                appDelegate.flushPendingURLs(to: tabManager)
            }
        }
        .onOpenURL { url in
            guard url.pageFlowIsOpenableDocument else { return }
            tabManager.closeFilePicker()
            tabManager.openDocument(url: url, isSecurityScoped: false)
        }
        .onDisappear {
            tabManager.flushActiveTabViewState()
            WindowRegistry.shared.unregister(tabManager)
        }
        .sheet(item: Self.passwordRequestBinding(in: tabManager)) { request in
            Self.passwordDialog(for: request, in: tabManager)
        }
    }

    static func passwordRequestBinding(in tabManager: TabManager) -> Binding<TabManager.PasswordPrompt?> {
        let presented = tabManager.pendingPasswordRequest
        return Binding(
            get: { presented },
            set: { request in
                guard request == nil, let presented else { return }
                tabManager.cancelPasswordPrompt(for: presented)
            }
        )
    }

    static func passwordDialog(for request: TabManager.PasswordPrompt, in tabManager: TabManager) -> PasswordDialogView {
        PasswordDialogView(
            fileName: request.url.lastPathComponent,
            submitTitle: request.purpose == .insertPages ? "Insert" : "Open",
            onSubmit: { password in
                tabManager.submitPassword(password, for: request)
            },
            onCancel: {
                tabManager.cancelPasswordPrompt(for: request)
            }
        )
    }
}

// MARK: - TabManager Holder

/// Lazily constructs and retains a window's `TabManager`. Construction is
/// deferred out of `TabContainerView.init` (which SwiftUI re-runs on every
/// scene recompute) so a re-init never builds a throwaway manager — see the
/// `holder` doc-comment on `TabContainerView`.
@MainActor
private final class TabManagerHolder {
    private var stored: TabManager?

    init() {}
    init(adopting manager: TabManager) { stored = manager }

    var manager: TabManager {
        if let stored { return stored }
        let created = TabManager()
        stored = created
        return created
    }
}

// MARK: - Window Registrar

/// Helper view that registers the TabManager with the global registry.
private struct WindowRegistrar: NSViewRepresentable {
    let tabManager: TabManager

    func makeNSView(context: Context) -> NSView {
        let view = WindowRegistrarView()
        view.tabManager = tabManager
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowRegistrarView: NSView {
    var tabManager: TabManager?
    private var isRegistered = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard let window = window, let tabManager = tabManager, !isRegistered else { return }

        WindowRegistry.shared.register(tabManager, window: window)
        isRegistered = true
    }
}
