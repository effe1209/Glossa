//
//  MarkupCursorOverride.swift
//  Glossa
//
//  Keeps a markup tool's cursor on while the pointer is over the app's window.
//  Controls and PDFKit set their own cursors as the pointer moves; racing
//  them from a timer shows a flicker between the two. Instead, while the
//  override is on and the pointer really is over that window, any other
//  cursor asked for is swapped for the tool's, so nothing fights. Anywhere
//  else (another app, another window on top, the title bar) it stands aside.
//

import AppKit
import ObjectiveC

enum MarkupCursorOverride {
    nonisolated(unsafe) static var cursor: NSCursor?
    nonisolated(unsafe) static weak var window: NSWindow?
    nonisolated(unsafe) private static var installed = false

    /// The pointer is over the window's content, the app is frontmost and no
    /// other window sits between the pointer and this one.
    static func pointerIsOverWindow() -> Bool {
        guard NSApp.isActive, let window, window.isVisible, window.isKeyWindow,
              let content = window.contentView else { return false }
        let screenPoint = NSEvent.mouseLocation
        guard NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
        let local = content.convert(window.convertPoint(fromScreen: screenPoint), from: nil)
        return content.bounds.contains(local)
    }

    static func install() {
        guard !installed else { return }
        installed = true
        guard let original = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.set)),
              let swizzled = class_getInstanceMethod(NSCursor.self, #selector(NSCursor.pf_set)) else { return }
        method_exchangeImplementations(original, swizzled)
    }
}

extension NSCursor {
    /// After the swap this is the original `set`; the original name runs this.
    @objc func pf_set() {
        if let override = MarkupCursorOverride.cursor, override !== self, MarkupCursorOverride.pointerIsOverWindow() {
            override.pf_set()
            return
        }
        pf_set()
    }
}
