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
        for (_, x) in dividers { addCursorRect(NSRect(x: x - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let divider = dividers.first(where: { abs($0.1 - x) <= 4 })?.0 else { return }
        if event.clickCount == 2, divider == .graph {
            onResetGraph?()
            return
        }
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            onDrag?(divider, convert(next.locationInWindow, from: nil).x)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface0.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let layout = columns.layout(in: bounds.width)
        for (_, x) in layout.dividers { NSRect(x: x.rounded() - 0.5, y: 9, width: 1, height: bounds.height - 18).fill() }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: 0.66]
        func caption(_ column: HistoryColumns.Column, in range: ClosedRange<CGFloat>?, rightAligned: Bool = false) {
            guard let range else { return }
            let string = NSAttributedString(string: column.title.uppercased(), attributes: attributes)
            let size = string.size()
            let x = rightAligned ? range.upperBound - 12 - size.width : range.lowerBound + 10
            guard x >= range.lowerBound + 2, x + size.width <= range.upperBound - 2 else { return }
            string.draw(at: CGPoint(x: x, y: bounds.midY - size.height / 2))
        }
        caption(.label, in: layout.label, rightAligned: true)
        caption(.graph, in: layout.graph)
        caption(.commit, in: layout.commit)
        caption(.author, in: layout.author)
        caption(.sha, in: layout.sha)
        caption(.date, in: layout.date, rightAligned: true)

        // A thin bar under the caption shows which part of a wider graph is in view.
        if let graph = layout.graph, graphContentWidth > columns.graph + 0.5 {
            let track = NSRect(x: graph.lowerBound + 4, y: bounds.height - 4, width: columns.graph - 8, height: 2)
            let knobWidth = max(track.width * columns.graph / graphContentWidth, 12)
            let fraction = columns.graphScrollX / (graphContentWidth - columns.graph)
            Theme.inkFaint.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX + (track.width - knobWidth) * fraction, y: track.minY, width: knobWidth, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// The history table. A sideways scroll over the graph column moves the graph inside its column, and the column boundaries can be dragged over the rows.
final class HistoryTableView: NSTableView {
    /// Returns true when the scroll was used for the graph.
    var onGraphScroll: ((_ deltaX: CGFloat, _ at: NSPoint) -> Bool)?
    var columns = HistoryColumns() { didSet { if columns != oldValue { window?.invalidateCursorRects(for: self) } } }
    var onDrag: ((HistoryColumns.Column, CGFloat) -> Void)?
    var onResetGraph: (() -> Void)?

    private var dividers: [(HistoryColumns.Column, CGFloat)] { columns.layout(in: bounds.width).dividers }

    override func scrollWheel(with event: NSEvent) {
        let isSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if isSideways, onGraphScroll?(event.scrollingDeltaX, convert(event.locationInWindow, from: nil)) == true { return }
        super.scrollWheel(with: event)
    }

    override func resetCursorRects() {
        for (_, x) in dividers { addCursorRect(NSRect(x: x - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let divider = dividers.first(where: { abs($0.1 - x) <= 4 })?.0 else {
            super.mouseDown(with: event)
            return
        }
        if event.clickCount == 2, divider == .graph {
            onResetGraph?()
            return
        }
        // The table would otherwise start its own row tracking, so the drag is followed here until the button comes up.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            onDrag?(divider, convert(next.locationInWindow, from: nil).x)
        }
    }
}

/// A faint line over the whole height of the history at the column boundary under the mouse. It never takes clicks.
final class ColumnGuideView: NSView {
    var columns = HistoryColumns() { didSet { if columns != oldValue { needsDisplay = true } } }
    private var hovered: HistoryColumns.Column? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        hovered = columns.layout(in: bounds.width).dividers.first { abs($0.1 - x) <= 4 }?.0
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let hovered, let x = columns.layout(in: bounds.width).dividers.first(where: { $0.0 == hovered })?.1 else { return }
        Theme.ink.withAlphaComponent(0.18).setFill()
        NSRect(x: x.rounded() - 1, y: 0, width: 2, height: bounds.height).fill()
    }
}
