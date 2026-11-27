// swift-tools-version:5.9
// Runs the pure layout tests without the app: `swift test` in this directory.
// The sources are symlinks to the app's own files.
import PackageDescription

let package = Package(
    name: "PageFlowLayout",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PageFlowLayout", path: "Sources/PageFlowLayout"),
        .testTarget(name: "PageFlowLayoutTests", dependencies: ["PageFlowLayout"], path: "Tests/PageFlowLayoutTests"),
    ]
)
