//
//  AttachmentLinkRecognizer.swift
//  PageFlow
//
//  Which absolute image links in a note name one of the app's own attachment folders. Images pasted
//  into a note that had no folder sit there behind absolute links; when the note is saved they move
//  beside it (`PastedImageStore.adoptFallbackImages`). Two folders can hold such images:
//    - Glossa's own, `Application Support/Glossa/Attachments`;
//    - PageFlow's, `Application Support/PageFlow/Attachments`, which older notes still link to, and
//      which a copy of the files into Glossa's folder does not change: the links in a document are the
//      reader's and are never rewritten.
//
//  This only judges a path. It reads no folder's contents, copies nothing, and creates no read-through:
//  a link names one file, and that file is used only if the note asks for it. PageFlow's folder counts
//  only where it can be reached (not in a sandboxed build).
//

import Foundation

nonisolated struct AttachmentLinkRecognizer: Equatable, Sendable {
    /// The recognised folders, Glossa's first.
    let folders: [URL]

    init(folders: [URL]) { self.folders = folders }

    /// Glossa's attachments folder, and PageFlow's when `paths` can reach it.
    init(paths: ApplicationSupportPaths) {
        var folders = [paths.directory(for: .attachments)]
        if paths.legacyIsReachable { folders.append(paths.legacyDirectory(for: .attachments)) }
        self.init(folders: folders)
    }

    /// Whether `file` lies inside a recognised folder: standardised, so a `..` cannot lead out of one, and
    /// a lookalike name (`Attachments-old`) does not match. The folder itself is not a file in it.
    func recognizes(_ file: URL) -> Bool {
        let path = file.standardizedFileURL.path
        return folders.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Whether `file` is a plain file that is there: a regular file, not a link (a link in the folder
    /// could lead anywhere), not a folder, not missing.
    func isPlainFile(_ file: URL) -> Bool {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG
    }

    /// A link to adopt: inside a recognised folder and a plain file.
    func canAdopt(_ file: URL) -> Bool { recognizes(file) && isPlainFile(file) }
}
