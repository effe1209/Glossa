//
//  SplitDividerHandle.swift
//  PageFlow
//
//  The divider between the two panes of a side-by-side window. An AppKit view,
//  so the left-right resize cursor shows over it whatever the panes beneath
//  (a PDF view manages its own cursor) and a drag follows the pointer exactly.
//  Double-click returns the panes to half and half.
//

import AppKit
import SwiftUI

struct SplitDividerHandle: NSViewRepresentable {
    static let hitWidth: CGFloat = 12

    let totalWidth: CGFloat
    let fraction: CGFloat
    let onChange: (CGFloat) -> Void
    let onReset: () -> Void
    var onDragState: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> HandleView { HandleView() }

    func updateNSView(_ view: HandleView, context: Context) {
        view.totalWidth = totalWidth
        view.fraction = fraction
        view.onChange = onChange
        view.onReset = onReset
        view.onDragState = onDragState
    }

    final class HandleView: NSView {
        var totalWidth: CGFloat = 1
        var fraction: CGFloat = 0.5
        var onChange: (CGFloat) -> Void = { _ in }
        var onReset: () -> Void = {}
        var onDragState: (Bool) -> Void = { _ in }
        private var dragStartX: CGFloat = 0
        private var dragStartFraction: CGFloat = 0.5
        private var isHovered = false { didSet { needsDisplay = true } }
        private var isDragging = false { didSet { needsDisplay = true } }

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                           owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
        override func mouseEntered(with event: NSEvent) { isHovered = true; NSCursor.resizeLeftRight.set() }
        override func mouseExited(with event: NSEvent) { isHovered = false }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { onReset(); return }
            dragStartX = event.locationInWindow.x
            dragStartFraction = fraction
            isDragging = true
            onDragState(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard totalWidth > 0 else { return }
            onChange(dragStartFraction + (event.locationInWindow.x - dragStartX) / totalWidth)
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            isDragging = false
            onDragState(false)
        }

        override func draw(_ dirtyRect: NSRect) {
            let active = isHovered || isDragging
            let lineWidth: CGFloat = active ? 3 : 1
            let line = NSRect(x: (bounds.width - lineWidth) / 2, y: 0, width: lineWidth, height: bounds.height)
            (active ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.separatorColor).setFill()
            line.fill()
            // A grip in the middle says it can be moved.
            let grip = NSRect(x: (bounds.width - 6) / 2, y: bounds.midY - 18, width: 6, height: 36)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: grip, xRadius: 3, yRadius: 3).fill()
            (active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: grip.insetBy(dx: 2, dy: 6), xRadius: 1, yRadius: 1).fill()
        }
    }
}
