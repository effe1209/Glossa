//
//  MigrationView.swift
//  PageFlow
//
//  The window that offers the import from PageFlow, and the one that asks for access to be
//  allowed again afterwards. Both only show and ask; the work is in `MigrationSession`
//  (what each button does) and `CombinedMigrationCoordinator` (what it writes).
//

import SwiftUI
import AppKit

// MARK: - Import offer

struct MigrationView: View {
    @Bindable var session: MigrationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch session.phase {
            case .choosing: choosing
            case .running: running
            case .confirmingLargeAttachments(let bytes): confirming(bytes)
            case .finished(let result): finished(result)
            case .failed(let reason): failed(reason)
            case .nothingLeft(let text): nothingLeft(text)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    // MARK: Offer

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import your data from PageFlow?").font(.title2.bold())
            Text("Glossa found data from PageFlow on this Mac. Importing copies it into Glossa. PageFlow's own data is only read: nothing in it is changed, moved or deleted.")
                .fixedSize(horizontal: false, vertical: true)
            if let summary = session.prompt.preferences.summary {
                SummaryList(summary: summary, heading: "Settings and document data")
                Text("Open sessions and window positions are not imported. Folder and file permissions are checked one by one; those that no longer work are listed afterwards so you can allow them again. Glossa restarts once to use the imported settings.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let offer = session.prompt.files.offer {
                FilesOfferList(offer: offer)
                Text("Each file is checked before it is copied; files that are not sound are skipped and listed. Nothing in Glossa's folders is overwritten, and links in your notes are not changed. Copying the files does not need a restart.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Don't Import Ever") { session.choose(.neverImport) }
                Spacer()
                Button("Not Now") { session.choose(.notNow) }
                Button("Import") { session.choose(.importNow) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(runningText)
            }
            if session.isPastPointOfNoReturn {
                Text("Files are being put in place. This can no longer be cancelled, and it will be done in a moment.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if session.prompt.files.offer != nil {
                HStack {
                    Spacer()
                    Button("Cancel") { session.cancel() }.disabled(!session.canCancel)
                }
            }
        }
    }

    private var runningText: String {
        if session.isPastPointOfNoReturn { return "Finishing the import…" }
        return session.isCancelling ? "Cancelling…" : "Importing…"
    }

    // MARK: Large attachments

    private func confirming(_ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Copy \(FilesResultSummary.mebibytes(bytes)) of attachments?").font(.title2.bold())
            Text("PageFlow's attachments are larger than 500 MiB. Copying them takes that much room in Glossa's folder, and the originals stay where they are. Nothing has been copied yet.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now") { session.confirmLargeAttachments(false) }
                Button("Copy") { session.confirmLargeAttachments(true) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Result

    private func finished(_ result: MigrationSession.MigrationResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(result.title).font(.title2.bold())
            if let summary = result.preferences {
                SummaryList(summary: summary, heading: "Settings and document data imported")
                if !summary.authorizations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(summary.authorizations.count) files or folders need your permission again")
                            .font(.headline)
                        Text("Their old permissions do not carry over. After the restart Glossa lists them and asks you to allow each one. Their paths are kept until then.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let files = result.files { FilesResultList(summary: files) }
            if result.filesPostponed {
                Text("The attachments were not copied. Glossa will offer them again the next time it starts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if result.needsRestart {
                Text("Glossa has to restart to use the imported settings.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if result.needsRestart {
                    Button("Restart Glossa") { session.restart() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Continue") { session.close() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if session.preferencesApplied {
                Text("Your settings were imported, but the rest could not be completed").font(.title2.bold())
                Text("\(reason). PageFlow's data was not touched. Glossa has to restart to use the imported settings; what is left will be offered again.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("The import could not be completed").font(.title2.bold())
                Text("Nothing was recorded as done: \(reason). PageFlow's data was not touched, and you can try again at the next launch.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if session.preferencesApplied {
                    Button("Back") { session.backToChoice() }
                    Button("Restart Glossa") { session.close() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Close") { session.close() }
                    Button("Back") { session.backToChoice() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func nothingLeft(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nothing left to import").font(.title2.bold())
            Text(text).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(session.preferencesApplied ? "Restart Glossa" : "Continue") { session.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

private func categoryTitle(_ category: ApplicationSupportPaths.Category) -> String {
    switch category {
    case .recovery: return "Unsaved-note recovery copies"
    case .attachments: return "Pasted images (attachments)"
    case .epubAnnotations: return "EPUB highlights, notes and bookmarks"
    }
}

private struct FilesOfferList: View {
    let offer: FilesOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Files to copy").font(.headline)
            ForEach(offer.lines, id: \.category) { line in
                HStack {
                    Text(categoryTitle(line.category))
                    Spacer()
                    Text("\(line.files) · \(FilesResultSummary.mebibytes(line.bytes))").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !offer.unreadable.isEmpty {
                Text("Glossa could not read \(offer.unreadable.map(categoryTitle).joined(separator: ", ")) in PageFlow's folder, so it will not be copied now. The rest is copied, the copy is not recorded as done, and it is offered again at the next start, so it can be tried once the permissions are fixed.")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if offer.interrupted {
                Text("An earlier copy was interrupted. It starts again from the beginning; nothing is resumed silently.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FilesResultList: View {
    let summary: FilesResultSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.completed && summary.copiedFiles + summary.identical > 0 ? "Files copied" : "Files").font(.headline)
            ForEach(summary.lines, id: \.category) { line in
                HStack {
                    Text(categoryTitle(line.category))
                    Spacer()
                    Text("\(line.copied) copied · \(FilesResultSummary.mebibytes(line.bytes))").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if summary.identical > 0 { note("\(summary.identical) already in Glossa, identical.") }
            if summary.conflicts > 0 { note("\(summary.conflicts) differ from what Glossa already has; Glossa's were kept.") }
            if summary.invalid > 0 { note("\(summary.invalid) were not sound and were skipped.") }
            if summary.overJSONLimit > 0 { note("\(summary.overJSONLimit) were over the 64 MiB limit for JSON files and were skipped.") }
            if summary.completed, summary.copiedFiles + summary.identical == 0, summary.invalid > 0 {
                note("Nothing was sound enough to copy, so nothing was copied. This is recorded, and it will not be offered again.")
            }
            if let problem = summary.problem { Text(problem).font(.callout).foregroundStyle(.orange) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func note(_ text: String) -> some View { Text(text).font(.callout).foregroundStyle(.secondary) }
}

private struct SummaryList: View {
    let summary: MigrationSummary
    let heading: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.headline)
            ForEach(summary.carriedOver, id: \.title) { line in
                HStack {
                    Text(line.title)
                    Spacer()
                    Text("\(line.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if !summary.needAttention.isEmpty {
                Text("Partly: \(summary.needAttention.joined(separator: ", ")) (some permissions have to be allowed again)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if summary.keptFromGlossa > 0 {
                Text("\(summary.keptFromGlossa) items Glossa already has are kept as they are.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Allow again

/// The permissions still to be allowed again. One instance for the app: the menu, the launch
/// prompt and the window all read the same list, which lives in Glossa's preferences and so
/// survives a restart.
@MainActor
@Observable
final class PendingAuthorizationsModel {
    static let shared = PendingAuthorizationsModel()

    /// The list the menu item and the window both watch; it follows any change with no restart.
    let state: PendingAuthorizationsState
    var items: [PendingAuthorization] { state.items }
    var message: String?
    private let destination: MigrationDestination
    @ObservationIgnored private var recentFiles: RecentFilesManager?

    init(defaults: UserDefaults = AppDefaults.store) {
        destination = UserDefaultsDestination(defaults: defaults)
        state = PendingAuthorizationsState(destination: destination)
    }

    func configure(recentFiles: RecentFilesManager) { self.recentFiles = recentFiles }

    func refresh() { state.refresh() }

    /// Asks for one folder or file through the standard open panel; only the reader's choice creates access.
    func allow(_ item: PendingAuthorization) {
        message = nil
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        switch service().attempt(item) {
        case .alreadyAuthorized: message = "\(name) already has access; it was taken off the list."
        case .granted: break
        case .cancelled: break
        case .wrongSelection(let expected): message = "That is not \(expected). Choose \(expected) to allow it."
        case .notVerified: message = "Access to \(name) could not be confirmed, so it stays on the list."
        }
        refresh()
    }

    private func service() -> PendingAuthorizationService {
        let recent = recentFiles
        let inspector = LegacyBookmarkInspector(scoped: true)
        return PendingAuthorizationService(
            destination: destination,
            isAlreadyAuthorized: { item in
                let url = URL(fileURLWithPath: item.path)
                if item.isFolder { return FolderAccessStore.shared.hasWorkingAccess(to: url) }
                guard let entry = recent?.recentFiles.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path }),
                      let data = entry.securityScopedBookmarkData else { return false }
                if case .valid = inspector.inspect(data) { return true }
                return false
            },
            pick: { item in
                let url = URL(fileURLWithPath: item.path)
                let panel = NSOpenPanel()
                panel.canChooseFiles = !item.isFolder
                panel.canChooseDirectories = item.isFolder
                panel.allowsMultipleSelection = false
                panel.directoryURL = item.isFolder ? url : url.deletingLastPathComponent()
                panel.message = item.isFolder ? "Allow Glossa to read \(url.lastPathComponent) again."
                                              : "Choose \(url.lastPathComponent) to allow Glossa to open it again."
                panel.prompt = "Allow"
                guard panel.runModal() == .OK, let chosen = panel.url else { return .cancelled }
                return .chosen(chosen)
            },
            grant: { item, chosen in
                if item.isFolder { FolderAccessStore.shared.allow(chosen, covering: URL(fileURLWithPath: item.path)) }
                else { recent?.addRecentFile(chosen, isSecurityScoped: true) }
            },
            verify: { item, chosen in
                if item.isFolder { return FolderAccessStore.shared.hasWorkingAccess(to: URL(fileURLWithPath: item.path)) }
                guard let data = try? chosen.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil),
                      case .valid = inspector.inspect(data) else { return false }
                return true
            })
    }
}

struct AuthorizationView: View {
    @Bindable var model: PendingAuthorizationsModel
    let close: () -> Void

    var body: some View {
        AuthorizationContent(items: model.items, message: model.message, allow: { model.allow($0) }, close: close)
    }
}
