//
//  AuthorizationContent.swift
//  PageFlow
//
//  What the "Allow Files and Folders" window shows, as a view that depends on nothing but the list it
//  is given, so that its layout can be measured on its own. `AuthorizationView` feeds it from the model.
//
//  Layout. The window is sized from the content's ideal size, and a ScrollView has none: left alone it
//  collapses to zero height and the rows are there but cannot be seen. So the list takes the height of
//  its rows, up to `listMaxHeight`, and scrolls beyond that. The order matters: the cap goes on the
//  ScrollView first and `fixedSize` after it. With `fixedSize` first, the ScrollView takes the height of
//  all its rows, the cap only crops the space it is given, and the rows spill over the button.
//

import SwiftUI

struct AuthorizationContent: View {
    /// The tallest the list gets; more rows than that scroll.
    static let listMaxHeight: CGFloat = 260

    let items: [PendingAuthorization]
    let message: String?
    let allow: (PendingAuthorization) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Files and folders to allow again").font(.title2.bold())
            Text("After the import from PageFlow, these could not keep their permission. Allow each one you still use. Glossa does not read them until you do; their paths are kept in the meantime.")
                .fixedSize(horizontal: false, vertical: true)
            if items.isEmpty {
                Text("Nothing left to allow.").foregroundStyle(.secondary)
            } else {
                list
            }
            if let message { Text(message).font(.callout).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button(items.isEmpty ? "Done" : "Later") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(items, id: \.path) { item in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: item.path).lastPathComponent).font(.body)
                            Text(item.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button(item.isFolder ? "Allow Folder…" : "Allow File…") { allow(item) }
                    }
                }
            }
        }
        .frame(maxHeight: Self.listMaxHeight)           // the cap first…
        .fixedSize(horizontal: false, vertical: true)    // …then the height of the rows, up to it
    }
}
