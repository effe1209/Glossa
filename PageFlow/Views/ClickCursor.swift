import SwiftUI

extension View {
    /// Let SwiftUI own cursor entry, exit and view removal. Apply to an action,
    /// not its surrounding panel; `when` releases editable content back to text cursors.
    func pageFlowClickCursor(when isAction: Bool = true) -> some View {
        modifier(ClickCursor(isAction: isAction))
    }
}

private struct ClickCursor: ViewModifier {
    let isAction: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        // With a markup tool on, its icon is the pointer everywhere.
        if MarkupCursorState.shared.isActive {
            content
        } else {
            content.pointerStyle(isAction ? (isEnabled ? .link : .default) : nil)
        }
    }
}
