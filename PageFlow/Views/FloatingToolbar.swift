//
//  FloatingToolbar.swift
//  PageFlow
//
//  The PDF item set for the shared top-chrome toolbar slot: document, zoom,
//  annotation, and page-navigation controls inside the shared
//  `GlassToolbarShell` (see GlassToolbar.swift).
//

import SwiftUI

struct FloatingToolbar: View {
    @Bindable var pdfManager: PDFManager
    @Bindable var annotationManager: AnnotationManager
    @Bindable var commentManager: CommentManager
    @Bindable var bookmarkManager: BookmarkManager
    var undoAvailability: UndoAvailability
    var onUndo: () -> Void
    var onRedo: () -> Void
    var onOpenFilePicker: () -> Void
    @Binding var showingOutline: Bool
    @Binding var showingComments: Bool
    var onFind: () -> Void
    @State private var settingsManager = SettingsManager.shared

    /// The markup buttons are tools that stay on: turning one on also marks
    /// any text already selected; clicking it again turns it off.
    private func toolAction(_ tool: AnnotationManager.StickyMarkup) {
        annotationManager.toggleSticky(tool)
        annotationManager.applyStickyMarkup()
    }

    private var isBookmarked: Bool { bookmarkManager.isBookmarked(pdfManager.currentPageIndex) }

    var body: some View {
        GlassToolbarShell {
            GlassToolbarButton(
                icon: pdfManager.interactionMode == .pan ? "cursorarrow" : "hand.raised",
                help: "Switch between pan and text selection",
                action: { pdfManager.interactionMode = pdfManager.interactionMode == .pan ? .select : .pan },
                disabled: !pdfManager.hasDocument,
                label: "Pan",
                isOn: pdfManager.interactionMode == .pan
            )
            ZoomToolbarGroup(
                canZoomOut: pdfManager.canZoomOut,
                canZoomIn: pdfManager.canZoomIn,
                onZoomOut: { pdfManager.zoomOut() },
                onZoomIn: { pdfManager.zoomIn() },
                reset: .init(help: "Actual size (100%)", disabled: !pdfManager.canResetZoom,
                             action: { pdfManager.resetZoom() }),
                fit: .init(isFitted: pdfManager.isAutoScaling, isAvailable: pdfManager.hasDocument,
                           action: { pdfManager.zoomToFit() })
            )
            GlassToolbarButton(icon: "magnifyingglass", help: "Find", action: onFind,
                               disabled: !pdfManager.hasDocument, label: "Find")
            GlassToolbarButton(
                // Shows the mode you are in: stacked pages flowing on, or one page.
                icon: pdfManager.isContinuousScroll ? "rectangle.split.1x2" : "rectangle.portrait",
                help: pdfManager.isContinuousScroll ? "Continuous scrolling. Click for one page at a time" : "One page at a time. Click for continuous scrolling",
                action: { pdfManager.isContinuousScroll.toggle() },
                disabled: !pdfManager.hasDocument,
                label: pdfManager.isContinuousScroll ? "Continuous Scrolling" : "Single Page"
            )
            GlassToolbarButton(
                icon: "rotate.right",
                help: "Rotate page clockwise",
                action: { pdfManager.rotateClockwise() },
                disabled: !pdfManager.permissions.editPages,
                label: "Rotate"
            )
            Divider().frame(height: 16)
            GlassToolbarButton(
                icon: "underline",
                help: "Underline: marks the selection and stays on for the next ones. Click again to turn off",
                action: { toolAction(.underline) },
                disabled: !pdfManager.permissions.annotate || !pdfManager.hasDocument,
                label: "Underline",
                isOn: annotationManager.stickyMarkup == .underline,
                showsOnDot: true
            )
            GlassToolbarButton(
                icon: "highlighter",
                help: "Highlight: marks the selection and stays on for the next ones. Click again to turn off",
                action: { toolAction(.highlight) },
                disabled: !pdfManager.permissions.annotate || !pdfManager.hasDocument,
                label: "Highlight",
                isOn: annotationManager.stickyMarkup == .highlight,
                showsOnDot: true
            )
            // The colours of the tool in use, shown while it is on.
            if let tool = annotationManager.stickyMarkup {
                MarkupColorSwatches(
                    presets: tool == .highlight ? settingsManager.highlightPresets : settingsManager.underlinePresets,
                    isChosen: { preset in
                        preset.color.isEqual(to: tool == .highlight ? annotationManager.highlightColor : annotationManager.underlineColor)
                    },
                    choose: { preset in
                        if tool == .highlight { annotationManager.highlightColor = preset.color }
                        else { annotationManager.underlineColor = preset.color }
                    }
                )
                .transition(.opacity)
            }
            GlassToolbarButton(
                icon: "text.bubble",
                help: "Add a comment",
                action: { _ = commentManager.addComment() },
                disabled: !pdfManager.permissions.annotate,
                label: "Add Comment"
            )
            GlassToolbarButton(
                icon: showingComments ? "bubble.right.fill" : "bubble.right",
                help: "Show or hide comments",
                action: { withAnimation(.easeInOut(duration: DesignTokens.animationFast)) { showingComments.toggle() } },
                disabled: !pdfManager.hasDocument,
                label: "Comments",
                isOn: showingComments
            )
            GlassToolbarButton(
                icon: isBookmarked ? "bookmark.fill" : "bookmark",
                help: "Add or remove a bookmark on this page",
                action: { bookmarkManager.toggleBookmark(at: pdfManager.currentPageIndex) },
                disabled: !pdfManager.hasDocument,
                label: "Bookmark",
                isOn: isBookmarked
            )
            Divider().frame(height: 16)
            GlassToolbarButton(icon: "arrow.uturn.backward", help: undoAvailability.undoTitle, action: onUndo,
                               disabled: !undoAvailability.canUndo, label: "Undo")
            GlassToolbarButton(icon: "arrow.uturn.forward", help: undoAvailability.redoTitle, action: onRedo,
                               disabled: !undoAvailability.canRedo, label: "Redo")
            Divider().frame(height: 16)
            // The jump history: back to where an internal link or outline
            // jump left from. Page by page is the arrow keys' job.
            GlassToolbarButton(icon: "chevron.left", help: "Go back", action: { pdfManager.goBack() },
                               disabled: !pdfManager.canGoBack, label: "Back")
            GlassToolbarButton(icon: "chevron.right", help: "Go forward", action: { pdfManager.goForward() },
                               disabled: !pdfManager.canGoForward, label: "Forward")
        }
    }
}
