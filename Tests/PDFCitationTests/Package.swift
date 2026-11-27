// swift-tools-version:5.9
// Runs the PDF/note citation tests (link format, document identity, registry, resolver,
// citing notes) without the app: `swift test` in this directory.
// The sources are symlinks to the app's own files.
import PackageDescription

let package = Package(
    name: "PDFCitation",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PDFCitation", path: "Sources/PDFCitation"),
        .testTarget(name: "PDFCitationTests", dependencies: ["PDFCitation"], path: "Tests/PDFCitationTests"),
    ]
)
