import AppKit

/// Column captions above the history, aligned with the columns the rows draw. The boundaries can be dragged, and a right click picks the columns.
final class HistoryHeaderView: NSView {
    var columns = HistoryColumns() { didSet { if columns != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    /// Full width of the graph with all its lanes; wider than the column means the graph can be scrolled.
    var graphContentWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var onDrag: ((HistoryColumns.Column, CGFloat) -> Void)?
    /// Double click on the graph boundary: back to the automatic width.
    var onResetGraph: (() -> Void)?
    var makeMenu: (() -> NSMenu)?

    override var isFlipped: Bool { true }

    private var dividers: [(HistoryColumns.Column, CGFloat)] { columns.layout(in: bounds.width).dividers }

    override func resetCursorRects() {
        ColumnDividers.addCursorRects(to: self, at: dividers.map(\.1))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        guard let divider = ColumnDividers.hit(convert(event.locationInWindow, from: nil).x, in: dividers) else { return }
        if event.clickCount == 2, divider == .graph {
            onResetGraph?()
            return
        }
        ColumnDividers.followDrag(in: self) { onDrag?(divider, $0) }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface0.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - Theme.Stroke.hairline, width: bounds.width, height: Theme.Stroke.hairline).fill()
        let layout = columns.layout(in: bounds.width)
        for (_, x) in layout.dividers { NSRect(x: x.rounded() - Theme.Stroke.hairline / 2, y: Theme.ColumnHeader.dividerInset, width: Theme.Stroke.hairline, height: bounds.height - 2 * Theme.ColumnHeader.dividerInset).fill() }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern]
        func caption(_ column: HistoryColumns.Column, in range: ClosedRange<CGFloat>?, rightAligned: Bool = false) {
            guard let range else { return }
            let string = NSAttributedString(string: column.title.uppercased(with: AppLanguage.locale), attributes: attributes)
            let size = string.size()
            let x = rightAligned ? range.upperBound - Theme.Cell.trailing - size.width : range.lowerBound + Theme.Cell.leading
            guard x >= range.lowerBound + Theme.Cell.captionClearance, x + size.width <= range.upperBound - Theme.Cell.captionClearance else { return }
            string.draw(at: CGPoint(x: x, y: bounds.midY - size.height / 2))
        }
        caption(.label, in: layout.label, rightAligned: true)
        caption(.graph, in: layout.graph)
        caption(.commit, in: layout.commit)
        caption(.author, in: layout.author)
        caption(.sha, in: layout.sha)
        caption(.date, in: layout.date, rightAligned: true)

        // A thin bar under the caption shows which part of a wider graph is in view.
        if let graph = layout.graph, graphContentWidth > columns.graph + Theme.Stroke.hairline / 2 {
            let header = Theme.ColumnHeader.self
            let track = NSRect(x: graph.lowerBound + header.scrollTrackInset, y: bounds.height - header.scrollTrackInset, width: columns.graph - 2 * header.scrollTrackInset, height: header.scrollTrack)
            let knobWidth = max(track.width * columns.graph / graphContentWidth, header.minimumKnob)
            let fraction = columns.graphScrollX / (graphContentWidth - columns.graph)
            Theme.inkFaint.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX + (track.width - knobWidth) * fraction, y: track.minY, width: knobWidth, height: header.scrollTrack), xRadius: header.scrollTrack / 2, yRadius: header.scrollTrack / 2).fill()
        }
    }
}

/// The history table. A sideways scroll over the graph column moves the graph inside its column, and the column boundaries can be dragged over the rows.
final class HistoryTableView: NSTableView {
    /// Returns true when the scroll was used for the graph.
    var onGraphScroll: ((_ deltaX: CGFloat, _ at: NSPoint) -> Bool)?
    var columns = HistoryColumns() {
        didSet {
            guard columns != oldValue else { return }
            window?.invalidateCursorRects(for: self)
            onLayoutChange?()
        }
    }
    var onDrag: ((HistoryColumns.Column, CGFloat) -> Void)?
    var onResetGraph: (() -> Void)?
    /// The pointer moved to a point in the table, or left it (nil).
    var onHover: ((NSPoint?) -> Void)?
    /// A press in the label column; returns true when it was taken, such as a click on a "+n" counter.
    var onPressLabels: ((NSPoint) -> Bool)?
    /// A right-click in the label column: a pill's own menu, `.none` when the click was taken without a menu, nil for the row's menu.
    var labelMenu: ((NSPoint) -> LabelMenu?)?
    /// A click on a row with ⌘ or ⇧; returns true when it changed the selection.
    var onModifiedClick: ((_ row: Int, _ flags: NSEvent.ModifierFlags) -> Bool)?
    /// Columns, width or the whole content changed, so anything placed over the rows is stale.
    var onLayoutChange: (() -> Void)?
    /// These rows were drawn again from new models.
    var onRowsReloaded: ((IndexSet) -> Void)?
    /// Escape; returns true when something closed.
    var onCancel: (() -> Bool)?
    private var hoverArea: NSTrackingArea?

    private var dividers: [(HistoryColumns.Column, CGFloat)] { columns.layout(in: bounds.width).dividers }

    override func scrollWheel(with event: NSEvent) {
        let isSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if isSideways, onGraphScroll?(event.scrollingDeltaX, convert(event.locationInWindow, from: nil)) == true { return }
        super.scrollWheel(with: event)
    }

    override func resetCursorRects() {
        ColumnDividers.addCursorRects(to: self, at: dividers.map(\.1))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
        // Loading more rows only makes the table taller; that leaves the rows on screen where they were.
        if widthChanged { onLayoutChange?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { onHover?(nil) }
    }

    override func reloadData() {
        onLayoutChange?()
        super.reloadData()
    }

    override func reloadData(forRowIndexes rowIndexes: IndexSet, columnIndexes: IndexSet) {
        super.reloadData(forRowIndexes: rowIndexes, columnIndexes: columnIndexes)
        onRowsReloaded?(rowIndexes)
    }

    enum LabelMenu {
        case menu(NSMenu)
        case none
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        switch labelMenu?(convert(event.locationInWindow, from: nil)) {
        case .menu(let menu): menu
        case .none?: nil
        case nil: super.menu(for: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onCancel?() == true { return }
        super.keyDown(with: event)
    }

    /// Like a Finder list, a click into an inactive window already selects the row.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// NSTableView takes a click in a window that is not key yet as activation only, because it needs the window to become key. During such a click it claims not to, so the click selects as in a key window.
    /// An activating click and a background harness run both arrive before the window is key. Outside that click the table still needs a key window, or it could not become first responder.
    private var isTakingFirstClick = false
    override var needsPanelToBecomeKey: Bool {
        !isTakingFirstClick && super.needsPanelToBecomeKey
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let divider = ColumnDividers.hit(point.x, in: dividers) else {
            if event.clickCount == 1, onPressLabels?(point) == true { return }
            let flags = event.modifierFlags.intersection([.command, .shift])
            if !flags.isEmpty, row(at: point) >= 0, onModifiedClick?(row(at: point), flags) == true { return }
            guard let window, !window.isKeyWindow else { return super.mouseDown(with: event) }
            // NSTableView makes itself first responder only for a click in a key window; the keyboard should follow a first click too.
            window.makeFirstResponder(self)
            isTakingFirstClick = true
            defer { isTakingFirstClick = false }
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2, divider == .graph {
            onResetGraph?()
            return
        }
        ColumnDividers.followDrag(in: self) { onDrag?(divider, $0) }
    }
}
