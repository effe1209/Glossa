//
//  LegacyBookmarkInspector.swift
//  Glossa
//
//  Judges one bookmark made under another identity, on its own, without trusting it:
//  does it resolve, is it current, and can the file really be read with it? It never
//  creates a bookmark or a grant, and never changes a file.
//

import Foundation

nonisolated struct LegacyBookmarkInspector: Sendable {
    enum Result: Equatable, Sendable {
        case valid(URL)
        /// Resolves, but only after the file moved.
        case stale(URL)
        case unresolvable
        /// Resolves, but the file cannot be read.
        case unreachable(URL)

        var outcome: BookmarkFinding.Outcome {
            switch self {
            case .valid: return .valid
            case .stale: return .stale
            case .unresolvable: return .unresolvable
            case .unreachable: return .unreachable
            }
        }
    }

    /// Whether a bookmark is resolved with the sandbox's scope first. A unit test, which
    /// runs outside the sandbox, turns it off, as `PDFDocumentRegistry` does.
    var scoped: Bool = true

    func inspect(_ data: Data) -> Result {
        let attempts: [URL.BookmarkResolutionOptions] = scoped ? [[.withSecurityScope, .withoutUI], [.withoutUI]] : [[.withoutUI]]
        for options in attempts {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            let started = options.contains(.withSecurityScope) && url.startAccessingSecurityScopedResource()
            defer { if started { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path), FileManager.default.isReadableFile(atPath: url.path) else {
                return .unreachable(url)
            }
            return stale ? .stale(url) : .valid(url)
        }
        return .unresolvable
    }
}
