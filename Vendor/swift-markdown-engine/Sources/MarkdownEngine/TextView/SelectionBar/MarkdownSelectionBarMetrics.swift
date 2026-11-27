import CoreGraphics

/// Host-tunable size of the selection bar (the floating formatting bar over a
/// selection). 1 is the natural size.
public enum MarkdownSelectionBarMetrics {
    nonisolated(unsafe) public static var scale: CGFloat = 1
}
