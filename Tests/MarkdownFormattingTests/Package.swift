// swift-tools-version:5.9
// Tests for the Markdown editor's source formatting (formulas, alignment, colour), its code colours,
// and for how a note exports, without the app: `swift test` in this directory. The formatting tests
// run against the vendored engine itself; the export target is a symlink to the app's own MarkdownHTML.swift.
import PackageDescription

let package = Package(
    name: "MarkdownFormattingTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../Vendor/swift-markdown-engine"),
    ],
    targets: [
        .target(name: "MarkdownExport", path: "Sources/MarkdownExport"),
        .testTarget(
            name: "MarkdownFormattingTests",
            dependencies: [
                .product(name: "MarkdownEngine", package: "swift-markdown-engine"),
                .product(name: "MarkdownEngineCodeBlocks", package: "swift-markdown-engine"),
            ],
            path: "Tests/MarkdownFormattingTests"
        ),
        .testTarget(name: "MarkdownExportTests", dependencies: ["MarkdownExport"], path: "Tests/MarkdownExportTests"),
    ]
)
