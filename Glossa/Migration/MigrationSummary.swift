//
//  MigrationSummary.swift
//  Glossa
//
//  A report in the reader's words: what is carried over, what needs attention, what stays behind.
//  It counts and names; it never holds a preference value.
//

import Foundation

nonisolated struct MigrationSummary: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var title: String
        var count: Int
    }

    /// What an import writes (or wrote), grouped. Keys Glossa already has are not here: they win.
    var carriedOver: [Line] = []
    /// Of those, the groups that arrive reduced because some access has to be allowed again.
    var needAttention: [String] = []
    /// Keys left behind on purpose or because they are not what they should be.
    var leftBehind = 0
    var invalid = 0
    /// Keys Glossa already has: kept as they are.
    var keptFromGlossa = 0
    /// Files and folders that have to be allowed again, with the path.
    var authorizations: [PendingAuthorization] = []
    /// A failure, for a report that ended in one.
    var failure: String?

    var hasAnythingToImport: Bool { !carriedOver.isEmpty }
    var totalCarriedOver: Int { carriedOver.reduce(0) { $0 + $1.count } }

    init(_ report: MigrationReport) {
        var groups: [String: Int] = [:]
        var order: [String] = []
        var attention: [String] = []
        var written: Set<String>?
        if report.state == .applied { written = Set(report.written) }
        let kept = Set(report.keptFromDestination)

        for item in report.items {
            switch item.category {
            case .excluded: leftBehind += 1
            case .invalid: invalid += 1
            case .transferable, .needsVerification:
                guard let destinationKey = item.destinationKey else {
                    // Nothing could be verified (no key is written): it still needs the reader.
                    if item.category == .needsVerification { attention.append(Self.title(forSource: item.sourceKey)) }
                    continue
                }
                if kept.contains(destinationKey) { keptFromGlossa += 1; continue }
                if let written, !written.contains(destinationKey) { continue }
                let title = Self.title(forDestination: destinationKey)
                if groups[title] == nil { order.append(title) }
                groups[title, default: 0] += 1
                if item.category == .needsVerification { attention.append(title) }
            }
        }
        carriedOver = order.map { Line(title: $0, count: groups[$0] ?? 0) }
        needAttention = Array(Set(attention)).sorted()
        authorizations = PendingAuthorizationList.make(from: report.bookmarkFindings)
        if case .failed(let reason) = report.state { failure = reason }
    }

    static func title(forDestination key: String) -> String {
        switch key {
        case "recentFiles": return "Recent files"
        case "folderAccessBookmarks.v1": return "Folder permissions"
        case "droppedImageBookmarks.v1": return "Dropped-image permissions"
        case PDFDocumentRegistry.storageKey: return "PDF library (page links and notes)"
        case "documentViewStates.v2", "documentViewStates.v1": return "Reading positions"
        case "epubNarrationRate": return "Read-aloud speed"
        default:
            if key.hasPrefix("bookmarks:") { return "Page bookmarks" }
            if key.hasPrefix("glossa.markup.") || key == "settings.commentPresets" || key.hasSuffix("Presets") { return "Highlight, underline and comment colors" }
            if key.hasPrefix("settings.") || key.hasPrefix("glossa.") { return "Settings" }
            return "Other preferences"
        }
    }

    static func title(forSource key: String) -> String { title(forDestination: key == PDFDocumentRegistry.legacyStorageKey ? PDFDocumentRegistry.storageKey : key) }
}
