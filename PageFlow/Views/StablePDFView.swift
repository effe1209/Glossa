//
//  StablePDFView.swift
//  PageFlow
//
//  PDFView subclass that preserves vertical scroll position during horizontal resize.
//

import PDFKit
import AppKit

final class StablePDFView: PDFView {
    private let widthChangeTolerance: CGFloat = 0.5
    /// Reading position (a page + a point on that page) captured before a width
    /// change and restored after PDFKit reflows. Anchored to a `PDFDestination`, not a
    /// raw `contentView` scroll offset: when a width change rescales pages (fit-to-width
    /// / Auto-Scale), a saved absolute Y maps to *different* content afterward, and the
    /// drift is proportional to the page's depth in the document — so a raw offset gets
    /// visibly worse on later pages. A destination lands on the same content at any
    /// depth. (Mirrors the Projector's `restoreScrollPosition`.)
    private var pendingScrollRestoreDestination: PDFDestination?
    private var pendingScrollRestore: DispatchWorkItem?
    private weak var cachedDocumentScrollView: NSScrollView?
    private weak var configuredScrollView: NSScrollView?

    // MARK: - Interaction Mode (Pan vs Select)

    var interactionMode: InteractionMode = .select {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }
    private var lastPanLocation: NSPoint?
    private var isPanning = false

    /// The sticky markup tool in use: the pointer becomes its icon.
    var markupTool: AnnotationManager.StickyMarkup? {
        didSet {
            guard markupTool != oldValue else { return }
            markupCursor = markupTool.map { Self.makeCursor(for: $0) }
            updateMarkupCursorMonitor()
            window?.invalidateCursorRects(for: self)
            if let markupCursor { markupCursor.set() } else { NSCursor.arrow.set() }
        }
    }
    private var markupCursor: NSCursor?
    private var markupCursorMonitor: Any?
    private var markupCursorTimer: Timer?

    /// While a markup tool is on, its icon is the pointer everywhere in this
    /// window — over the toolbar and tab strip too. Controls set their own
    /// cursors (a hand, an arrow) as the pointer moves, so the icon is put
    /// back right after each such event instead of being fought for.
    private func updateMarkupCursorMonitor() {
        if let monitor = markupCursorMonitor {
            NSEvent.removeMonitor(monitor)
            markupCursorMonitor = nil
        }
        markupCursorTimer?.invalidate()
        markupCursorTimer = nil
        MarkupCursorState.shared.setActive(markupCursor != nil, owner: self)
        if let markupCursor, interactionMode != .pan {
            MarkupCursorOverride.install()
            MarkupCursorOverride.cursor = markupCursor
            MarkupCursorOverride.window = window
        } else if MarkupCursorOverride.window === window || MarkupCursorOverride.window == nil {
            MarkupCursorOverride.cursor = nil
        }
        guard markupCursor != nil else { return }
        // Other code's cursors are swapped for ours (`MarkupCursorOverride`);
        // this tick only puts ours on when nothing else has asked for one.
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let cursor = self.markupCursor, self.interactionMode != .pan,
                      MarkupCursorOverride.pointerIsOverWindow() else { return }
                cursor.set()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        markupCursorTimer = timer
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp,
                                             .cursorUpdate, .mouseEntered, .mouseExited]
        markupCursorMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            if let self, let cursor = self.markupCursor, event.window != nil, event.window === self.window,
               self.interactionMode != .pan {
                MarkupCursorOverride.window = self.window
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.markupCursor === cursor, MarkupCursorOverride.pointerIsOverWindow() else { return }
                    cursor.set()
                }
            }
            return event
        }
    }


    private static func makeCursor(for tool: AnnotationManager.StickyMarkup) -> NSCursor {
        let name = tool == .highlight ? "highlighter" : "underline"
        let size = NSSize(width: 24, height: 24)
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return .iBeam }
        func tinted(_ color: NSColor) -> NSImage {
            NSImage(size: size, flipped: false) { rect in
                let r = NSRect(origin: .zero, size: symbol.size)
                    .offsetBy(dx: (rect.width - symbol.size.width) / 2, dy: (rect.height - symbol.size.height) / 2)
                symbol.draw(in: r)
                color.set()
                r.fill(using: .sourceIn)
                return true
            }
        }
        let black = tinted(.black), white = tinted(.white)
        let image = NSImage(size: size, flipped: false) { rect in
            for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)] {
                white.draw(in: rect.offsetBy(dx: dx, dy: dy))
            }
            black.draw(in: rect)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 20))
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        unregisterDraggedTypes()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        unregisterDraggedTypes()
    }

    // Reject all drag operations to allow parent SwiftUI view to handle them
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        return false
    }

    var onLayoutGeometryChange: (() -> Void)?
    /// The view's size changed: a window resize, a sidebar, a layout reflow. Not called
    /// for scrolling, which moves content and not the view. A fit that follows the
    /// window re-measures here.
    var onViewportSizeChange: (() -> Void)?
    private var lastReportedViewportSize: NSSize = .zero
    private weak var observedGeometryHost: NSView?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let observedGeometryHost {
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification,
                                                      object: observedGeometryHost)
        }
        observedGeometryHost = superview
        if let superview {
            superview.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(hostGeometryChanged(_:)),
                name: NSView.frameDidChangeNotification, object: superview)
        }
        onLayoutGeometryChange?()
    }

    @objc private func hostGeometryChanged(_ notification: Notification) {
        onLayoutGeometryChange?()
    }

    override func layout() {
        super.layout()
        defer {
            onLayoutGeometryChange?()
            if bounds.size != lastReportedViewportSize {
                lastReportedViewportSize = bounds.size
                onViewportSizeChange?()
            }
        }

        if let scrollView = documentScrollView {
            if configuredScrollView !== scrollView {
                configureScrollers(scrollView)
                configuredScrollView = scrollView
            } else {
                syncScrollerVisibility(in: scrollView)
            }
        }
    }

    // MARK: - Scrollbar Management

    private enum ScrollerType: String {
        case vertical
        case horizontal
    }

    private var verticalTrackingArea: NSTrackingArea?
    private var horizontalTrackingArea: NSTrackingArea?
    private let verticalHoverZoneSize: CGFloat = 120.0 // 3x the original 40.0
    private let horizontalHoverZoneSize: CGFloat = 40.0
    private var needsTrackingAreaRefreshAfterLiveResize = false

    // State tracking to ensure robustness during layout updates
    private var isHoveringVertical = false
    private var isHoveringHorizontal = false
    private weak var observedContentView: NSClipView?

    // MARK: - Callbacks for Click Handling
    var onAnnotationClick: ((PDFAnnotation) -> Void)?
    var onAnnotationDeselect: (() -> Void)?
    var onAnnotationRemove: ((PDFAnnotation) -> Void)?
    var onAnnotationColorChange: ((PDFAnnotation, NSColor) -> Void)?
    var onCommentColorChange: ((PDFAnnotation, NSColor) -> Void)?
    var onControlScroll: ((NSEvent) -> Bool)?
    /// Returns false when this native view no longer owns the displayed document.
    var onUserZoom: ((PDFUserZoomIntent) -> Bool)?
    var onLinkNavigation: ((PDFPage) -> Void)?
    var onCopyPageAsMarkdown: (() -> Void)?
    var onCopyDocumentAsMarkdown: (() -> Void)?
    var onToggleBookmark: (() -> Void)?
    var onRequestFocus: (() -> Void)?
    /// A text selection was just completed by releasing the mouse.
    var onSelectionFinished: (() -> Void)?
    /// Esc: drop whatever tool or selection is active. True if it did.
    var onEscape: (() -> Bool)?

    /// The highlight or underline picked with the pointer, outlined so Delete
    /// has a visible target.
    var selectedMarkup: PDFAnnotation? {
        didSet {
            guard selectedMarkup !== oldValue else { return }
            updateSelectionOutline()
        }
    }
    private var selectionOutline: MarkupSelectionOutline?
    private var outlineObservers: [NSObjectProtocol] = []

    private func updateSelectionOutline() {
        guard let annotation = selectedMarkup,
              annotation.markupType == .highlight || annotation.markupType == .underline else {
            selectionOutline?.removeFromSuperview()
            selectionOutline = nil
            outlineObservers.forEach(NotificationCenter.default.removeObserver)
            outlineObservers = []
            return
        }
        let outline = selectionOutline ?? MarkupSelectionOutline(frame: bounds)
        outline.pdfView = self
        outline.annotation = annotation
        if outline.superview == nil {
            outline.autoresizingMask = [.width, .height]
            addSubview(outline)
            selectionOutline = outline
            let center = NotificationCenter.default
            var names: [(Notification.Name, AnyObject?)] = [
                (.PDFViewScaleChanged, self), (.PDFViewPageChanged, self), (.PDFViewVisiblePagesChanged, self),
                (.PDFViewSelectionChanged, self)
            ]
            if let clip = documentScrollView?.contentView {
                clip.postsBoundsChangedNotifications = true
                names.append((NSView.boundsDidChangeNotification, clip))
            }
            outlineObservers = names.map { name, object in
                center.addObserver(forName: name, object: object, queue: .main) { [weak outline] _ in
                    MainActor.assumeIsolated { outline?.needsDisplay = true }
                }
            }
        }
        outline.needsDisplay = true
    }
    /// The reader moved the view: a pan, the scrollers, or the keys. The wheel reaches
    /// the scroll view first, so the coordinator's monitor reports that.
    var onReaderScroll: (() -> Void)?

    private var rightClickMonitor: Any?

    // MARK: - Keyboard

    /// The stable per-document annotation identity, retained by the backend.
    weak var annotationOwner: AnyObject?

    /// This view is what's being read and holds the keyboard. A new view gets told
    /// before it has a window, which SwiftUI gives it some turns later, so the claim
    /// waits for one: asked once and given up on, the keyboard stayed in the window.
    var wantsKeyboard = false {
        didSet { if wantsKeyboard, !oldValue { claimKeyboard() } }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsKeyboard { claimKeyboard() }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if wantsKeyboard { claimKeyboard() }
    }

    /// Deferred a turn: responder changes inside a SwiftUI update re-enter AppKit.
    private func claimKeyboard() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.wantsKeyboard, let window = self.window, !self.isHiddenOrHasHiddenAncestor,
                  // Closing Find mid-comment leaves the keyboard in the comment.
                  self.annotationOwner.map({ CommentTextView.owns(window.firstResponder, owner: $0) }) != true else { return }
            window.makeFirstResponder(self)
        }
    }

    deinit {
        pendingScrollRestore?.cancel()
        NotificationCenter.default.removeObserver(self)
        removeRightClickMonitor()
        if let markupCursorMonitor { NSEvent.removeMonitor(markupCursorMonitor) }
        markupCursorTimer?.invalidate()
        if MarkupCursorOverride.window == nil { MarkupCursorOverride.cursor = nil }
        let id = ObjectIdentifier(self)
        Task { @MainActor in MarkupCursorState.shared.release(id) }
    }

    func setupRightClickMonitor() {
        // Guard against double-registration
        guard rightClickMonitor == nil else { return }

        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleRightClickEvent(event)
        }
    }

    func removeRightClickMonitor() {
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
            rightClickMonitor = nil
        }
    }

    private func handleRightClickEvent(_ event: NSEvent) -> NSEvent? {
        guard let window = self.window,
              event.window === window else {
            return event
        }

        guard let viewPoint = frontmostEventPoint(event) else { return event }

        // Asks the host to focus this tab (a no-op when it is already active).
        onRequestFocus?()

        let menu = buildContextMenu(for: event, at: viewPoint)
        menu.popUp(positioning: nil, at: viewPoint, in: self)
        return nil
    }

    private func configureScrollers(_ scrollView: NSScrollView) {
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if scrollView.scrollerKnobStyle != .default {
            scrollView.scrollerKnobStyle = .default
        }
        if scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = false
        }
        if scrollView.automaticallyAdjustsContentInsets {
            scrollView.automaticallyAdjustsContentInsets = false
        }

        let contentInsets = scrollView.contentInsets
        if contentInsets.top != 0 || contentInsets.left != 0 || contentInsets.bottom != 0 || contentInsets.right != 0 {
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }

        let scrollerInsets = scrollView.scrollerInsets
        if scrollerInsets.top != 0 || scrollerInsets.left != 0 || scrollerInsets.bottom != 0 || scrollerInsets.right != 0 {
            scrollView.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        }

        // Swap vertical scroller with custom GlassScroller if needed
        if !(scrollView.verticalScroller is GlassScroller) {
            let vScroller = GlassScroller()
            scrollView.verticalScroller = vScroller
        }
        
        // Swap horizontal scroller with custom GlassScroller if needed
        if !(scrollView.horizontalScroller is GlassScroller) {
            let hScroller = GlassScroller()
            scrollView.horizontalScroller = hScroller
        }
        for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller] {
            (scroller as? GlassScroller)?.onTrack = { [weak self] in self?.onReaderScroll?() }
        }

        // Enforce visibility state
        syncScrollerVisibility(in: scrollView)
        
        // Observe scrolling to enforce visibility - track contentView to handle document changes
        let contentView = scrollView.contentView
        if observedContentView !== contentView {
            // Remove old observer if contentView changed (e.g., when document changes)
            if let oldView = observedContentView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSView.boundsDidChangeNotification,
                    object: oldView
                )
            }

            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleScrollChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: contentView
            )
            observedContentView = contentView
        }
    }

    @objc private func handleScrollChanged(_ notification: Notification) {
        onLayoutGeometryChange?()
        guard let scrollView = documentScrollView else { return }
        // Enforce visibility state during scroll to prevent system override
        // We use animator() proxy to match the active animation state if any,
        // or just set it directly if we want strict enforcement.
        // Direct set is safer to fight system "flash" logic.
        syncScrollerVisibility(in: scrollView)
    }

    private var moveTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        // Whole-view move tracking (`.inVisibleRect` keeps it sized by itself),
        // so the markup cursor can be re-applied as the pointer moves.
        if moveTrackingArea == nil {
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            moveTrackingArea = area
        }

        if inLiveResize {
            needsTrackingAreaRefreshAfterLiveResize = true
            return
        }

        needsTrackingAreaRefreshAfterLiveResize = false

        if let vArea = verticalTrackingArea { removeTrackingArea(vArea) }
        if let hArea = horizontalTrackingArea { removeTrackingArea(hArea) }

        // Right edge (Vertical Scroller)
        let vWidth = min(verticalHoverZoneSize, bounds.width)
        let vRect = NSRect(x: bounds.maxX - vWidth, y: bounds.minY, width: vWidth, height: bounds.height)
        let vArea = NSTrackingArea(
            rect: vRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag],
            owner: self,
            userInfo: ["type": ScrollerType.vertical.rawValue]
        )
        addTrackingArea(vArea)
        verticalTrackingArea = vArea

        // Bottom edge (Horizontal Scroller)
        // Note: PDFView is flipped, so y: bounds.height is the bottom
        let hHeight = min(horizontalHoverZoneSize, bounds.height)
        let hRect = NSRect(x: bounds.minX, y: bounds.maxY - hHeight, width: bounds.width, height: hHeight)
        let hArea = NSTrackingArea(
            rect: hRect,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .enabledDuringMouseDrag],
            owner: self,
            userInfo: ["type": ScrollerType.horizontal.rawValue]
        )
        addTrackingArea(hArea)
        horizontalTrackingArea = hArea

        refreshScrollerHoverState()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoverState(isEntering: true, event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHoverState(isEntering: false, event: event)
    }

    private func updateHoverState(isEntering: Bool, event: NSEvent) {
        guard let scrollView = documentScrollView,
              let userInfo = event.trackingArea?.userInfo as? [String: String],
              let typeString = userInfo["type"],
              let type = ScrollerType(rawValue: typeString) else { return }

        switch type {
        case .vertical:
            setScrollerHover(.vertical, hovering: isEntering, in: scrollView, animated: true)
        case .horizontal:
            setScrollerHover(.horizontal, hovering: isEntering, in: scrollView, animated: true)
        }
    }

    private func refreshScrollerHoverState() {
        guard let window, let scrollView = documentScrollView else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let isInside = bounds.contains(point)
        let hoveringVertical = isInside && point.x >= bounds.width - verticalHoverZoneSize
        let hoveringHorizontal = isInside && point.y >= bounds.height - horizontalHoverZoneSize

        setScrollerHover(.vertical, hovering: hoveringVertical, in: scrollView, animated: false)
        setScrollerHover(.horizontal, hovering: hoveringHorizontal, in: scrollView, animated: false)
    }

    private func setScrollerHover(
        _ type: ScrollerType,
        hovering: Bool,
        in scrollView: NSScrollView,
        animated: Bool
    ) {
        let scroller: NSScroller?

        switch type {
        case .vertical:
            guard isHoveringVertical != hovering else { return }
            isHoveringVertical = hovering
            scroller = scrollView.verticalScroller
        case .horizontal:
            guard isHoveringHorizontal != hovering else { return }
            isHoveringHorizontal = hovering
            scroller = scrollView.horizontalScroller
        }

        guard let scroller else { return }
        let alpha: CGFloat = hovering ? 1.0 : 0.0

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                scroller.animator().alphaValue = alpha
            }
        } else {
            scroller.alphaValue = alpha
        }
    }

    private func syncScrollerVisibility(in scrollView: NSScrollView) {
        setScrollerAlpha(scrollView.verticalScroller, to: isHoveringVertical ? 1.0 : 0.0)
        setScrollerAlpha(scrollView.horizontalScroller, to: isHoveringHorizontal ? 1.0 : 0.0)
    }

    private func setScrollerAlpha(_ scroller: NSScroller?, to alpha: CGFloat) {
        guard let scroller, scroller.alphaValue != alpha else { return }
        scroller.alphaValue = alpha
    }

    /// Where the reader is. Resting in the gap above a page, as a view does just
    /// after going to one, `currentDestination` names the page before it, and going
    /// back there would land on the wrong page. The point stays exact, above the top
    /// of the page it now names.
    var readerDestination: PDFDestination? {
        guard let destination = currentDestination, let page = destination.page, let document,
              destination.point.y < page.bounds(for: displayBox).minY else { return currentDestination }
        let next = firstPageOfRow(after: document.index(for: page))
        guard next < document.pageCount, let nextPage = document.page(at: next) else { return destination }
        let inNext = convert(convert(destination.point, from: page), to: nextPage)
        return PDFDestination(page: nextPage, at: CGPoint(x: destination.point.x, y: inNext.y))
    }

    /// `readerDestination`, on the page the view is said to be on when that's another
    /// one on screen: PDFKit names the page with the most in view, not the one under
    /// the top edge, and a landing should leave the same page named as well as the
    /// same line at the top.
    func readerDestination(namedBy page: PDFPage?) -> PDFDestination? {
        guard let destination = readerDestination, let from = destination.page, let page, page !== from,
              visiblePages.contains(where: { $0 === page }) else { return readerDestination }
        return PDFDestination(page: page, at: convert(convert(destination.point, from: from), to: page))
    }

    /// Puts the view's top edge exactly on `destination`. `go(to:)` won't go past a
    /// page's own top, which a view at rest in the gap above it is, by as much as the
    /// gap: the same place read 8 pt off after every landing.
    func land(on destination: PDFDestination) {
        go(to: destination)
        guard let page = destination.page, let scrollView = documentScrollView, let documentView = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let wanted = clip.convert(convert(destination.point, from: page), from: self).y
        let origin = clip.isFlipped ? wanted : wanted - clip.bounds.height
        // The clip's own scroll runs on past the document's ends. A document shorter
        // than the clip, one row of pages centered in it, rests anywhere between them.
        let frame = documentView.frame
        let ends = (frame.minY, frame.maxY - clip.bounds.height)
        let clamped = min(max(origin, min(ends.0, ends.1)), max(ends.0, ends.1))
        guard abs(clamped - clip.bounds.minY) > 0.01 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clamped))
        scrollView.reflectScrolledClipView(clip)
    }

    /// In two-up, the page after a row's left page is that row's right page. A book's
    /// first page is a row of its own.
    private func firstPageOfRow(after index: Int) -> Int {
        guard displayMode == .twoUp || displayMode == .twoUpContinuous else { return index + 1 }
        let isLeftPage = (index % 2 == 0) != displaysAsBook
        return index + (isLeftPage ? 2 : 1)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        let savedDestination = readerDestination
        let widthChanged = oldWidth > 0 && abs(oldWidth - newSize.width) > widthChangeTolerance

        super.setFrameSize(newSize)

        guard widthChanged, let savedDestination else { return }
        scheduleScrollRestore(to: savedDestination)
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        let oldWidth = bounds.width
        let savedDestination = readerDestination

        super.resize(withOldSuperviewSize: oldSize)

        let widthChanged = abs(oldWidth - bounds.width) > widthChangeTolerance
        guard widthChanged, let savedDestination else { return }
        scheduleScrollRestore(to: savedDestination)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        pendingScrollRestore?.cancel()
        pendingScrollRestore = nil
        pendingScrollRestoreDestination = readerDestination
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        if needsTrackingAreaRefreshAfterLiveResize {
            updateTrackingAreas()
        }
        flushPendingScrollRestore()
    }

    private func scheduleScrollRestore(to destination: PDFDestination) {
        pendingScrollRestoreDestination = destination
        guard !inLiveResize else { return }
        guard pendingScrollRestore == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, let destination = self.pendingScrollRestoreDestination else { return }
            self.pendingScrollRestoreDestination = nil
            self.pendingScrollRestore = nil
            self.land(on: destination)
        }

        pendingScrollRestore = work
        DispatchQueue.main.async(execute: work)
    }

    private func flushPendingScrollRestore() {
        pendingScrollRestore?.cancel()
        pendingScrollRestore = nil

        guard let destination = pendingScrollRestoreDestination else { return }
        pendingScrollRestoreDestination = nil
        land(on: destination)
    }

    var documentScrollView: NSScrollView? {
        if let cachedDocumentScrollView,
           cachedDocumentScrollView.superview === self {
            return cachedDocumentScrollView
        }

        let scrollView = subviews.first { $0 is NSScrollView } as? NSScrollView
        cachedDocumentScrollView = scrollView
        return scrollView
    }

    // MARK: - Cursor Management

    override func resetCursorRects() {
        if interactionMode == .pan {
            addCursorRect(bounds, cursor: .openHand)
        } else {
            super.resetCursorRects()
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if interactionMode == .pan {
            (isPanning ? NSCursor.closedHand : NSCursor.openHand).set()
        } else if let markupCursor {
            markupCursor.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        onRequestFocus?()

        // Pan mode: initiate panning
        if interactionMode == .pan {
            lastPanLocation = convert(event.locationInWindow, from: nil)
            isPanning = true
            NSCursor.closedHand.push()
            return
        }

        // Select mode handling
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else {
            super.mouseDown(with: event)
            return
        }

        let pagePoint = convert(viewPoint, to: page)

        // Check for internal link clicks - push navigation state before PDFKit handles the link
        if let annotation = page.annotation(at: pagePoint),
           annotation.type == "Link",
           let action = annotation.action {
            // An internal link is a jump Back may return from. What it is judged
            // against is the page being read, not the visible page holding the link.
            if let target = (action as? PDFActionGoTo)?.destination.page {
                onLinkNavigation?(target)
            }
            // Let PDFView handle the actual navigation
            super.mouseDown(with: event)
            return
        }

        switch event.clickCount {
        case 1:
            // Single click: check for annotation
            if let annotation = page.annotation(at: pagePoint) {
                // Only consume click for comment annotations (have userName with UUID)
                // Regular highlights/underlines should allow text selection through them
                let isCommentAnnotation = annotation.userName.flatMap { UUID(uuidString: $0) } != nil
                if isCommentAnnotation {
                    onAnnotationClick?(annotation)
                    return
                }
                // For regular markup annotations, notify but allow text selection
                onAnnotationClick?(annotation)
            } else {
                onAnnotationDeselect?()
            }
            super.mouseDown(with: event)
        case 2:
            // Double click: select word
            if let selection = page.selectionForWord(at: pagePoint) {
                setCurrentSelection(selection, animate: false)
                onAnnotationDeselect?()
            } else {
                super.mouseDown(with: event)
            }
        case 3:
            // Triple click: select line
            if let selection = page.selectionForLine(at: pagePoint) {
                setCurrentSelection(selection, animate: false)
                onAnnotationDeselect?()
            } else {
                super.mouseDown(with: event)
            }
        default:
            super.mouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onEscape?() == true { return }
        // Delete and forward-delete remove the highlight or underline picked
        // with the pointer.
        if event.keyCode == 51 || event.keyCode == 117,
           let annotation = selectedMarkup, annotation.page != nil {
            onAnnotationRemove?(annotation)
            return
        }
        // Left and right turn pages (in any display mode).
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           interactionMode != .pan, event.keyCode == 123 || event.keyCode == 124 {
            onReaderScroll?()
            if event.keyCode == 123 { goToPreviousPage(nil) } else { goToNextPage(nil) }
            return
        }
        if Self.scrollingKeys.contains(event.keyCode) { onReaderScroll?() }
        super.keyDown(with: event)
    }

    /// Arrows, Page Up and Down, Home and End, and Space, which scroll PDFView.
    private static let scrollingKeys: Set<UInt16> = [123, 124, 125, 126, 116, 121, 115, 119, 49]

    override func scrollWheel(with event: NSEvent) {
        // Give control-scroll zoom handler a chance to consume the event
        if event.modifierFlags.contains(.control),
           onControlScroll?(event) == true {
            return
        }

        super.scrollWheel(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard interactionMode == .pan, let lastLocation = lastPanLocation else {
            super.mouseDragged(with: event)
            return
        }

        guard let scrollView = documentScrollView, let documentView = scrollView.documentView else { return }
        onReaderScroll?()

        let currentLocation = convert(event.locationInWindow, from: nil)
        // The page follows the hand, in the document's own coordinates.
        let delta = PDFDocumentScroll.panDelta(from: lastLocation, to: currentLocation, in: self, documentView: documentView)

        var origin = scrollView.contentView.bounds.origin
        origin.x += delta.x
        origin.y += delta.y

        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        lastPanLocation = currentLocation
    }

    override func mouseUp(with event: NSEvent) {
        guard interactionMode == .pan else {
            super.mouseUp(with: event)
            onSelectionFinished?()
            return
        }

        lastPanLocation = nil
        isPanning = false
        NSCursor.pop()
    }

    // MARK: - Context Menu State (used by StablePDFView+ContextMenu)

    var pendingRemovalAnnotation: PDFAnnotation?
    var pendingCommentAnnotation: PDFAnnotation?

    override func rightMouseDown(with event: NSEvent) {
        onRequestFocus?()

        let viewPoint = convert(event.locationInWindow, from: nil)
        let menu = buildContextMenu(for: event, at: viewPoint)
        menu.popUp(positioning: nil, at: viewPoint, in: self)
    }
}


/// A thin outline around the highlight or underline that Delete will remove.
/// It sits over the PDF view and never takes a click.
@MainActor
private final class MarkupSelectionOutline: NSView {
    weak var pdfView: PDFView?
    weak var annotation: PDFAnnotation?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let pdfView = pdfView as? StablePDFView, let annotation, let page = annotation.page,
              // Marking text is not picking markup: no outline with a tool on
              // or text selected.
              pdfView.markupTool == nil,
              pdfView.currentSelection?.string?.isEmpty != false else { return }
        NSColor.controlAccentColor.setStroke()
        for rect in lineRects(of: annotation) {
            let shown = pdfView.convert(rect, from: page).insetBy(dx: -1, dy: -1)
            let path = NSBezierPath(roundedRect: shown, xRadius: 2, yRadius: 2)
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    /// One rect per marked line, in page coordinates, from the annotation's
    /// quadrilaterals (the whole bounds if it has none).
    private func lineRects(of annotation: PDFAnnotation) -> [CGRect] {
        guard let points = annotation.quadrilateralPoints, points.count >= 4 else { return [annotation.bounds] }
        let origin = annotation.bounds.origin
        return stride(from: 0, to: points.count - 3, by: 4).map { start in
            let quad = points[start..<start + 4].map(\.pointValue)
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: origin.x + xs.min()!, y: origin.y + ys.min()!,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }
}
