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
        for (_, x) in dividers { addCursorRect(NSRect(x: x - Theme.dragThreshold, y: 0, width: 2 * Theme.dragThreshold, height: bounds.height), cursor: .resizeLeftRight) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu?() }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let divider = dividers.first(where: { abs($0.1 - x) <= Theme.dragThreshold })?.0 else { return }
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
        NSRect(x: 0, y: bounds.height - Theme.Stroke.hairline, width: bounds.width, height: Theme.Stroke.hairline).fill()
        let layout = columns.layout(in: bounds.width)
        for (_, x) in layout.dividers { NSRect(x: x.rounded() - Theme.Stroke.hairline / 2, y: Theme.ColumnHeader.dividerInset, width: Theme.Stroke.hairline, height: bounds.height - 2 * Theme.ColumnHeader.dividerInset).fill() }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern]
        func caption(_ column: HistoryColumns.Column, in range: ClosedRange<CGFloat>?, rightAligned: Bool = false) {
            guard let range else { return }
            let string = NSAttributedString(string: column.title.uppercased(), attributes: attributes)
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
        for (_, x) in dividers { addCursorRect(NSRect(x: x - Theme.dragThreshold, y: 0, width: 2 * Theme.dragThreshold, height: bounds.height), cursor: .resizeLeftRight) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let divider = dividers.first(where: { abs($0.1 - x) <= Theme.dragThreshold })?.0 else {
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
        hovered = columns.layout(in: bounds.width).dividers.first { abs($0.1 - x) <= Theme.dragThreshold }?.0
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let hovered, let x = columns.layout(in: bounds.width).dividers.first(where: { $0.0 == hovered })?.1 else { return }
        Theme.ink.withAlphaComponent(Theme.Wash.guide).setFill()
        NSRect(x: x.rounded() - Theme.Stroke.strand / 2, y: 0, width: Theme.Stroke.strand, height: bounds.height).fill()
    }
}
