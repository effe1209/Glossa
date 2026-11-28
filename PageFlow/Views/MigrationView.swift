//
//  MigrationView.swift
//  PageFlow
//
//  The window that offers the import from PageFlow, and the one that asks for access to be
//  allowed again afterwards. Both only show and ask; the work is in `LegacyMigrationCoordinator`.
//

import SwiftUI
import AppKit

// MARK: - Import offer

@MainActor
@Observable
final class MigrationViewModel {
    enum Phase: Equatable {
        case choosing
        case running
        case imported(MigrationSummary)
        case failed(String)
    }

    private(set) var phase: Phase = .choosing
    let summary: MigrationSummary
    private let coordinator: LegacyMigrationCoordinator
    /// Called when the window should close; true after an import, which needs a restart.
    private let finish: (_ relaunch: Bool) -> Void

    init(summary: MigrationSummary, coordinator: LegacyMigrationCoordinator, finish: @escaping (_ relaunch: Bool) -> Void) {
        self.summary = summary
        self.coordinator = coordinator
        self.finish = finish
    }

    func choose(_ choice: MigrationChoice) {
        switch choice {
        case .notNow:
            _ = coordinator.choose(.notNow)
            finish(false)
        case .neverImport:
            switch coordinator.choose(.neverImport) {
            case .failed(let reason): phase = .failed(reason)
            default: finish(false)
            }
        case .importNow:
            phase = .running
            Task { @MainActor in
                await Task.yield()
                switch coordinator.choose(.importNow) {
                case .imported(let report): phase = .imported(MigrationSummary(report))
                case .failed(let reason): phase = .failed(reason)
                default: phase = .failed("the import did not run")
                }
            }
        }
    }

    func restart() { finish(true) }
    func close() { finish(false) }
    func backToChoice() { phase = .choosing }
}

struct MigrationView: View {
    @Bindable var model: MigrationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .choosing: choosing
            case .running: running
            case .imported(let summary): imported(summary)
            case .failed(let reason): failed(reason)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var choosing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import your data from PageFlow?").font(.title2.bold())
            Text("Glossa found settings and document data from PageFlow on this Mac. Importing copies them into Glossa. PageFlow's own data is only read: nothing in it is changed, moved or deleted.")
                .fixedSize(horizontal: false, vertical: true)
            SummaryList(summary: model.summary, heading: "Will be imported")
            Text("Open sessions, Recovery files, attachments and window positions are not imported. Folder and file permissions are checked one by one; those that no longer work are listed afterwards so you can allow them again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Don't Import Ever") { model.choose(.neverImport) }
                Spacer()
                Button("Not Now") { model.choose(.notNow) }
                Button("Import") { model.choose(.importNow) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private var running: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Importing…")
        }
    }

    private func imported(_ summary: MigrationSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import finished").font(.title2.bold())
            SummaryList(summary: summary, heading: "Imported")
            if !summary.authorizations.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(summary.authorizations.count) files or folders need your permission again")
                        .font(.headline)
                    Text("Their old permissions do not carry over. After the restart Glossa lists them and asks you to allow each one. Their paths are kept until then.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Glossa has to restart to use the imported data.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Restart Glossa") { model.restart() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("The import could not be completed").font(.title2.bold())
            Text("Nothing was imported and the import is not recorded as done: \(reason). PageFlow's data was not touched, and you can try again at the next launch.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Close") { model.close() }
                Button("Back") { model.backToChoice() }.keyboardShortcut(.defaultAction)
            }
        }
    }
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Files and folders to allow again").font(.title2.bold())
            Text("After the import from PageFlow, these could not keep their permission. Allow each one you still use. Glossa does not read them until you do; their paths are kept in the meantime.")
                .fixedSize(horizontal: false, vertical: true)
            if model.items.isEmpty {
                Text("Nothing left to allow.").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.items, id: \.path) { item in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.body)
                                    Text(item.path).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                Button(item.isFolder ? "Allow Folder…" : "Allow File…") { model.allow(item) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            if let message = model.message { Text(message).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(model.items.isEmpty ? "Done" : "Later") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
