//
//  CitingNotesView.swift
//  PageFlow
//
//  The "Notes" section of a PDF's right-hand panel: the Markdown notes that
//  quote the open document, with the pages they cite. A click opens the note.
//  The list itself is looked up by `TabManager.refreshCitingNotes`.
//

import SwiftUI

struct CitingNotesView: View {
    let notes: [PDFCitingNote]
    let onOpen: (PDFCitingNote) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                if notes.isEmpty {
                    VStack(spacing: DesignTokens.spacingSM) {
                        Image(systemName: "text.quote")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No notes quote this PDF yet")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("Select text and choose Copy to Note as Markdown")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignTokens.spacingXL)
                } else {
                    ForEach(notes) { note in row(note) }
                }
            }
            .padding(.horizontal, DesignTokens.spacingSM)
            .padding(.bottom, DesignTokens.spacingMD)
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ note: PDFCitingNote) -> some View {
        Button { onOpen(note) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title).font(.system(size: 14, weight: .medium)).foregroundStyle(.primary).lineLimit(2)
                Text(detail(note)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            .padding(DesignTokens.spacingSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glossaClickCursor()
        .help(note.url.path)
    }

    private func detail(_ note: PDFCitingNote) -> String {
        let pages = note.pages.map(String.init).joined(separator: ", ")
        return (note.count == 1 ? "1 quote" : "\(note.count) quotes") + " · p. " + pages
    }
}
