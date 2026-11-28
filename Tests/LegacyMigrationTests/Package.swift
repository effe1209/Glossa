// swift-tools-version:5.9
// Runs the PageFlow -> Glossa migration tests (allowlist, report, dry run, marker, bookmarks,
// the PDF registry's key) without the app: `swift test` in this directory.
// The sources are symlinks to the app's own files. Every test uses a temporary folder or an
// isolated UserDefaults suite; none reads or writes the reader's real preferences.
import PackageDescription

let package = Package(
    name: "LegacyMigration",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LegacyMigration", path: "Sources/LegacyMigration"),
        .testTarget(name: "LegacyMigrationTests", dependencies: ["LegacyMigration"], path: "Tests/LegacyMigrationTests"),
    ]
)
