// swift-tools-version:5.9
// Runs the pure PDF zoom and rail-geometry tests without the app: `swift test` in this directory.
// The sources are symlinks to the app's own files.
import PackageDescription

let package = Package(
    name: "PDFZoomFit",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PDFZoomFit", path: "Sources/PDFZoomFit"),
        .testTarget(name: "PDFZoomFitTests", dependencies: ["PDFZoomFit"], path: "Tests/PDFZoomFitTests"),
    ]
)
