//
//  SplitPartnerChooserView.swift
//  PageFlow
//
//  The empty half of a side-by-side window while it waits for its second tab: the
//  open tabs with a preview, Open File, New Markdown, the recent files, and a drop
//  zone that lights up only over this half. Whatever opens here becomes the pane
//  (`TabManager.followActiveTabInSplit`).
//

import SwiftUI
import PDFKit
import UniformTypeIdentifiers

struct SplitPartnerChooserView: View {
    let tabManager: TabManager
    /// The top chrome the content starts below.
    let topInset: CGFloat

    @Environment(RecentFilesManager.self) private var recentFilesManager
    @State private var isDropTargeted = false

    private var anchorTitle: String {
        tabManager.tabs.first { $0.id == tabManager.splitChooserAnchor }?.displayTitle ?? ""
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingLG) {
                header
                let open = tabManager.splitChooserTabs
                if !open.isEmpty {
                    section("Open tabs")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 170), spacing: DesignTokens.spacingMD)],
                              alignment: .leading, spacing: DesignTokens.spacingMD) {
                        ForEach(open) { tab in card(tab) }
                    }
                }
                HStack(spacing: DesignTokens.spacingMD) {
                    actionButton("Open File…", systemImage: "folder") { tabManager.splitOpenFile() }
                    actionButton("New Markdown", systemImage: "square.and.pencil") { tabManager.splitNewMarkdown() }
                }
                let recents = Array(recentFilesManager.recentFiles.prefix(5))
                if !recents.isEmpty {
                    section("Recent")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(recents) { recent in
                            Button { tabManager.splitOpenRecent(recent, from: recentFilesManager) } label: {
                                HStack(spacing: DesignTokens.spacingSM) {
                                    Image(systemName: recent.url.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text")
                                        .foregroundStyle(.secondary)
                                    Text(recent.displayName).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 5)
                                .padding(.horizontal, DesignTokens.spacingSM)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .glossaClickCursor()
                        }
                    }
                }
                Text("or drag a PDF, EPUB or Markdown file onto this side")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DesignTokens.spacingLG)
            .padding(.top, topInset + DesignTokens.spacingMD)
            .padding(.bottom, DesignTokens.spacingLG)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            // Only this half lights up for a drop.
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.tabCornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2))
                    .padding(.top, topInset)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
            guard !fileProviders.isEmpty else { return false }
            let manager = tabManager
            Task { @MainActor in
                var urls: [URL] = []
                for provider in fileProviders {
                    if let url = await provider.loadDroppedFileURL(), url.glossaIsOpenableDocument { urls.append(url) }
                }
                if !urls.isEmpty { manager.splitOpenDropped(urls) }
            }
            return true
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Open beside this tab").font(.title3.weight(.semibold))
                Text(anchorTitle).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button { tabManager.cancelSplitChooser() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .glossaClickCursor()
            .help("Close the side-by-side view")
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: systemImage) }
            .buttonStyle(.plain)
            .glossaClickCursor()
            .padding(.horizontal, DesignTokens.spacingMD)
            .padding(.vertical, DesignTokens.spacingSM)
            .glossaLiquidGlassPanel(.primaryButton)
    }

    private func card(_ tab: TabModel) -> some View {
        Button { tabManager.chooseSplitPartner(tab.id) } label: {
            VStack(spacing: 6) {
                preview(for: tab)
                    .frame(width: 112, height: 144)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
                Text(tab.displayTitle).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                    .frame(width: 112)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glossaClickCursor()
    }

    @ViewBuilder
    private func preview(for tab: TabModel) -> some View {
        if let page = tabManager.sessions[tab.id]?.pdfManager?.document?.page(at: 0) {
            Image(nsImage: page.thumbnail(of: CGSize(width: 112, height: 144), for: .cropBox))
                .resizable().scaledToFit()
        } else {
            Image(systemName: (tabManager.contentKind(for: tab.id) ?? .pdf).tabIconSystemName)
                .font(.system(size: 30)).foregroundStyle(.secondary)
        }
    }
}
