import AppKit

/// A view filled with one theme color; follows light and dark on its own.
final class FillView: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        bounds.fill()
    }
}

/// A flat bar in the chrome color with one hairline edge.
final class BarView: NSView {
    enum Edge { case top, bottom }
    private let edge: Edge

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface1.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: edge == .bottom ? bounds.height - 1 : 0, width: bounds.width, height: 1).fill()
    }
}

/// Widths of the history columns. The commit text takes whatever is left between the graph and the author.
struct HistoryColumns: Equatable {
    var label: CGFloat = Theme.Graph.labelColumn
    var graph: CGFloat = Theme.Graph.firstLane + Theme.Graph.lane
    var author: CGFloat = Theme.Graph.authorColumn
    var date: CGFloat = Theme.Graph.dateColumn
    /// How far the graph is scrolled to the left inside its column.
    var graphScrollX: CGFloat = 0

    static let minimumCommitWidth: CGFloat = 160

    /// Below a certain width the author column gives way to the commit text.
    func showsAuthor(in width: CGFloat) -> Bool { width >= Theme.Graph.authorMinimumWidth }

    /// The draggable boundaries between the columns of a history `width` points wide, with their x positions.
    func dividers(in width: CGFloat) -> [(HistoryHeaderView.Divider, CGFloat)] {
        var result: [(HistoryHeaderView.Divider, CGFloat)] = [(.label, label), (.graph, label + graph)]
        if showsAuthor(in: width) { result.append((.author, width - date - author)) }
        result.append((.date, width - date))
        return result
    }
}

/// Column captions above the history, aligned with the columns the rows draw. The boundaries between columns can be dragged.
final class HistoryHeaderView: NSView {
    enum Divider { case label, graph, author, date }

    var columns = HistoryColumns() { didSet { if columns != oldValue { needsDisplay = true; window?.invalidateCursorRects(for: self) } } }
    /// Full width of the graph with all its lanes; wider than the column means the graph can be scrolled.
    var graphContentWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    /// A divider was dragged to `x`, in this view's coordinates.
    var onDrag: ((Divider, CGFloat) -> Void)?
    /// Double click on the graph divider: back to the automatic width.
    var onResetGraph: (() -> Void)?
    private var dragging: Divider?

    override var isFlipped: Bool { true }

    private var dividers: [(Divider, CGFloat)] { columns.dividers(in: bounds.width) }

    override func resetCursorRects() {
        for (_, x) in dividers { addCursorRect(NSRect(x: x - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let hit = dividers.first(where: { abs($0.1 - x) <= 4 })?.0 else { return }
        if event.clickCount == 2, hit == .graph {
            onResetGraph?()
            return
        }
        dragging = hit
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragging else { return }
        onDrag?(dragging, convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface0.setFill()
        bounds.fill()
        Theme.hairline.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        for (_, x) in dividers { NSRect(x: x.rounded() - 0.5, y: 9, width: 1, height: bounds.height - 18).fill() }
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: 0.66]
        func caption(_ text: String, x: CGFloat, rightAligned: Bool = false, maxX: CGFloat = .greatestFiniteMagnitude) {
            let string = NSAttributedString(string: text.uppercased(), attributes: attributes)
            let size = string.size()
            let origin = rightAligned ? x - size.width : x
            guard origin + size.width <= maxX else { return }
            string.draw(at: CGPoint(x: origin, y: bounds.midY - size.height / 2))
        }
        let graphEnd = columns.label + columns.graph
        caption("Branch / Tag", x: columns.label - 14, rightAligned: true)
        caption("Graph", x: columns.label + 8, maxX: graphEnd - 4)
        caption("Commit", x: graphEnd + 12)
        if columns.showsAuthor(in: bounds.width) { caption("Autor", x: bounds.width - columns.date - columns.author) }
        caption("Datum", x: bounds.width - 12, rightAligned: true)

        // A thin bar under the caption shows which part of a wider graph is in view.
        if graphContentWidth > columns.graph + 0.5 {
            let track = NSRect(x: columns.label + 4, y: bounds.height - 4, width: columns.graph - 8, height: 2)
            let knobWidth = max(track.width * columns.graph / graphContentWidth, 12)
            let travel = track.width - knobWidth
            let fraction = columns.graphScrollX / (graphContentWidth - columns.graph)
            Theme.inkFaint.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX + travel * fraction, y: track.minY, width: knobWidth, height: 2), xRadius: 1, yRadius: 1).fill()
        }
    }
}

/// The history table. A sideways scroll over the graph column moves the graph inside its column instead of the table.
final class HistoryTableView: NSTableView {
    /// Returns true when the scroll was used for the graph.
    var onGraphScroll: ((_ deltaX: CGFloat, _ at: NSPoint) -> Bool)?
    /// The column boundaries can be dragged anywhere over the rows, not only in the header.
    var columns = HistoryColumns() { didSet { if columns != oldValue { window?.invalidateCursorRects(for: self) } } }
    var onDrag: ((HistoryHeaderView.Divider, CGFloat) -> Void)?
    var onResetGraph: (() -> Void)?

    override func resetCursorRects() {
        for (_, x) in columns.dividers(in: bounds.width) { addCursorRect(NSRect(x: x - 4, y: 0, width: 8, height: bounds.height), cursor: .resizeLeftRight) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let divider = columns.dividers(in: bounds.width).first(where: { abs($0.1 - x) <= 4 })?.0 else {
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

    override func scrollWheel(with event: NSEvent) {
        let isSideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        if isSideways, onGraphScroll?(event.scrollingDeltaX, convert(event.locationInWindow, from: nil)) == true { return }
        super.scrollWheel(with: event)
    }
}
