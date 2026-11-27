//
//  MarkdownFormatToolbar.swift
//  PageFlow
//
//  The Markdown item set for the shared top-chrome toolbar slot, inside the
//  same `GlassToolbarShell` as the PDF `FloatingToolbar` — identical shell,
//  identical position (`TopChromeView`), and the SAME section structure:
//  open | zoom cluster + sidebar toggle + Find | actions (Bold/Italic/
//  Underline/Heading). The magnifier cluster VISUALLY zooms the document
//  (per-document, persisted — PDF parity), the same as pinch / ⌘± / Ctrl-scroll;
//  the base font size lives in Settings.
//

import SwiftUI
import MarkdownEngine

@MainActor
struct MarkdownFormatToolbar: View {
    @Bindable var content: MarkdownContent
    /// Source beside an uneditable preview.
    var isSplitView = false
    var onToggleSplit: () -> Void = {}
    /// The active tab's sidebar state (`TabSession.uiState.showingOutline` via
    /// `TabManager` — the same canonical slot the PDF toolbar binds).
    @Binding var showingOutline: Bool
    /// Find, as PDF and EPUB put it after the sidebar button.
    var canFind = true
    var onFind: () -> Void = {}

    @State private var settingsManager = SettingsManager.shared

    var body: some View {
        GlassToolbarShell {
            exportMenu
            Divider().frame(height: 16)
            ZoomToolbarGroup(
                canZoomOut: content.canZoomOut,
                canZoomIn: content.canZoomIn,
                onZoomOut: { content.zoomOut() },
                onZoomIn: { content.zoomIn() },
                reset: .init(help: "Actual size", disabled: !content.canResetZoom,
                             action: { content.resetZoom() }),
                fit: .init(isFitted: content.isWidthFitted, isAvailable: !content.isAwaitingOpen,
                           label: "Fit Text to Window", help: "Fit the reading text to the window width",
                           allowsRefitting: true, action: { content.zoomToFit() })
            )
            SidebarFindToolbarGroup(showingSidebar: $showingOutline, showsSidebarButton: false, canFind: canFind && !isSplitView, onFind: onFind)
            GlassToolbarButton(icon: "rectangle.split.2x1", help: isSplitView ? "Hide the source" : "Show the source beside a preview",
                               action: onToggleSplit, label: "Source and Preview", isOn: isSplitView, showsOnDot: true)
            Divider().frame(height: 16)
            // the reference editor's host toolbar: Table, Checklist and Insert ▾; the
            // marks live on the selection bar (doc 24 §6.12).
            ForEach(MarkdownFormatCommand.toolbar) { command in
                GlassToolbarButton(
                    icon: command.iconSystemName,
                    help: command.help,
                    action: { content.requestFormat(command) },
                    disabled: !content.isFormatEnabled(command),
                    label: command.title
                )
            }
            commentsButton
            Menu {
                ForEach(MarkdownFormatCommand.insertMenu) { command in
                    Button(command.title) { content.requestFormat(command) }
                        .disabled(!content.isFormatEnabled(command))
                }
                Menu("Callout") {
                    ForEach(MarkdownCallout.kinds, id: \.id) { kind in
                        Button { content.insertCallout(kind.id) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                }
            } label: {
                GlassToolbarLabel(icon: "plus", interactive: true, magnifies: false)
            }
            .menuStyle(.borderlessButton)
            .pageFlowClickCursor()
            .menuIndicator(.hidden)
            .fixedSize()
            .proximityMagnified()
            // Follows the "Show button tooltips" setting like the other buttons.
            .toolbarTooltip("Insert", enabled: settingsManager.showTooltips)
            .accessibilityLabel("Insert")
        }
    }

    /// Export leads the toolbar: PDF, HTML or a Word document, the same as File ▸ Export As.
    /// Opening and creating documents are in the File menu and the tab bar.
    private var exportMenu: some View {
        Menu {
            ForEach(DocumentExporter.Format.allCases, id: \.self) { format in
                Button(format.menuTitle) { content.exportDocument(as: format) }
            }
        } label: {
            GlassToolbarLabel(icon: "square.and.arrow.up", interactive: content.canExport, magnifies: false)
        }
        .menuStyle(.borderlessButton)
        .pageFlowClickCursor()
        .menuIndicator(.hidden)
        .fixedSize()
        .proximityMagnified()
        .disabled(!content.canExport)
        .toolbarTooltip("Export as PDF, HTML or Word", enabled: settingsManager.showTooltips)
        .accessibilityLabel("Export")
    }

    /// the reference editor's Comments button (doc 25 §1.4): "Show comments" while they
    /// are hidden (with the open count as a badge), "All comments" in the
    /// margin, "Floating comments" in the list.
    private var commentsButton: some View {
        // PDF's comments icon, filled while the list (the panel) shows.
        GlassToolbarButton(icon: content.isShowingCommentsList ? "bubble.right.fill" : "bubble.right",
                           help: content.commentsButtonHelp, action: { content.toggleCommentsList() },
                           label: "Comments", isOn: content.isShowingCommentsList)
            .overlay(alignment: .topTrailing) {
                if let count = content.hiddenCommentBadge {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 4, y: -4)
                        .allowsHitTesting(false)
                }
            }
    }
}
