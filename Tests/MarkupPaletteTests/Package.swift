// swift-tools-version:5.9
// Tests for the markup palette (colours, their layer and storage, contrast).
// Run with `swift test` in this directory. The sources are symlinks to the app's own files.
import PackageDescription

let package = Package(
    name: "MarkupPalette",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MarkupPalette", path: "Sources/MarkupPalette"),
        .testTarget(name: "MarkupPaletteTests", dependencies: ["MarkupPalette"], path: "Tests/MarkupPaletteTests"),
    ]
)
