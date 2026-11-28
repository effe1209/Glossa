//
//  SidebarHeaderView.swift
//  PageFlow
//
//  Header controls for the document sidebar.
//

import SwiftUI

/// Whether a sidebar is held open, and the action that flips it.
struct SidebarPin {
    let isPinned: Bool
    let toggle: () -> Void
}

struct SidebarHeaderView: View {
    @Binding var mode: SidebarMode
    @Binding var isEditingPages: Bool
    let onClose: () -> Void
    /// The sidebar can be held open (pinned) or only peek in while the
    /// pointer is at the edge; nil for sidebars that are always pinned.
    var pin: SidebarPin?

    var body: some View {
        HStack {
            GlassSidebarTitle(text: headerTitle)

            Spacer()

            // Reordering needs the sidebar held open: a peek can't be edited.
            if mode == .thumbnails, pin?.isPinned ?? true {
                editPagesButton
            }

            modeToggle
            if let pin {
                Button {
                    pin.toggle()
                } label: {
                    Image(systemName: pin.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .padding(DesignTokens.spacingXS)
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .glossaClickCursor()
                .help(pin.isPinned ? "Unpin the sidebar" : "Keep the sidebar open")
                .accessibilityLabel(pin.isPinned ? "Unpin Sidebar" : "Pin Sidebar")
            }
            GlassSidebarCloseButton(label: "Close Sidebar") {
                isEditingPages = false
                onClose()
            }
        }
    }

    private var headerTitle: String {
        switch mode {
        case .outline: return "Contents"
        case .thumbnails: return "Thumbnails"
        case .bookmarks: return "Bookmarks"
        }
    }

    private var editPagesButton: some View {
        Button {
            withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                isEditingPages.toggle()
            }
        } label: {
            Text(isEditingPages ? "Done" : "Edit")
                .font(.system(size: 12))
                .padding(.horizontal, DesignTokens.spacingSM)
                .padding(.vertical, DesignTokens.spacingXS)
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .glossaClickCursor()
        .accessibilityLabel(isEditingPages ? "Done" : "Edit Pages")
    }

    private var modeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: DesignTokens.animationFast)) {
                isEditingPages = false
                mode = nextMode
            }
        } label: {
            Image(systemName: modeIcon)
                .font(.system(size: DesignTokens.sidebarToggleIconSize))
                .foregroundStyle(.primary)
                .frame(
                    width: DesignTokens.sidebarToggleButtonSize,
                    height: DesignTokens.sidebarToggleButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glossaClickCursor()
        .help(modeHelpText)
        .accessibilityLabel(modeHelpText)
    }

    private var nextMode: SidebarMode {
        switch mode {
        case .outline: return .thumbnails
        case .thumbnails: return .bookmarks
        case .bookmarks: return .outline
        }
    }

    private var modeIcon: String {
        switch mode {
        case .outline: return "square.grid.2x2"
        case .thumbnails: return "bookmark"
        case .bookmarks: return "list.bullet"
        }
    }

    private var modeHelpText: String {
        switch mode {
        case .outline: return "Show Thumbnails"
        case .thumbnails: return "Show Bookmarks"
        case .bookmarks: return "Show Contents"
        }
    }
}
