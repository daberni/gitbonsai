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

/// Widths and visibility of the history columns. The commit text is always shown and takes whatever is left.
struct HistoryColumns: Equatable {
    enum Column: String, CaseIterable {
        case label, graph, commit, author, sha, date

        var title: String {
            switch self {
            case .label: "Branch / Tag"
            case .graph: "Graph"
            case .commit: "Commit"
            case .author: "Autor"
            case .sha: "SHA"
            case .date: "Datum"
            }
        }

        var minimumWidth: CGFloat {
            switch self {
            case .label: 80
            case .graph: Theme.Graph.firstLane + Theme.Graph.lane / 2
            case .commit: 160
            case .author: 60
            case .sha: 60
            case .date: 64
            }
        }
    }

    /// Where each visible column sits in a history of a given width.
    struct Layout {
        var label: ClosedRange<CGFloat>?
        var graph: ClosedRange<CGFloat>?
        var commit: ClosedRange<CGFloat>
        var author: ClosedRange<CGFloat>?
        var sha: ClosedRange<CGFloat>?
        var date: ClosedRange<CGFloat>?

        /// The draggable boundaries: the right edge of the columns left of the commit text, the left edge of those right of it.
        var dividers: [(Column, CGFloat)] {
            var result: [(Column, CGFloat)] = []
            if let label { result.append((.label, label.upperBound)) }
            if let graph { result.append((.graph, graph.upperBound)) }
            if let author { result.append((.author, author.lowerBound)) }
            if let sha { result.append((.sha, sha.lowerBound)) }
            if let date { result.append((.date, date.lowerBound)) }
            return result
        }
    }

    var label: CGFloat = Theme.Graph.labelColumn
    var graph: CGFloat = Theme.Graph.firstLane + Theme.Graph.lane
    var author: CGFloat = Theme.Graph.authorColumn
    var sha: CGFloat = 80
    var date: CGFloat = Theme.Graph.dateColumn
    var hidden: Set<Column> = []
    /// How far the graph is scrolled to the left inside its column.
    var graphScrollX: CGFloat = 0

    static let standard = HistoryColumns(hidden: [.sha])

    func shows(_ column: Column) -> Bool { column == .commit || !hidden.contains(column) }

    func width(of column: Column) -> CGFloat {
        switch column {
        case .label: label
        case .graph: graph
        case .commit: 0
        case .author: author
        case .sha: sha
        case .date: date
        }
    }

    /// Columns right of the commit text give way when the history gets too narrow, the author first.
    func layout(in width: CGFloat) -> Layout {
        var x: CGFloat = 0
        var label: ClosedRange<CGFloat>?
        var graph: ClosedRange<CGFloat>?
        if shows(.label) { label = x...(x + self.label); x += self.label }
        if shows(.graph) { graph = x...(x + self.graph); x += self.graph }
        var right: [Column] = [.author, .sha, .date].filter(shows)
        while !right.isEmpty, width - x - right.map(self.width(of:)).reduce(0, +) < Column.commit.minimumWidth { right.removeFirst() }
        var ranges: [Column: ClosedRange<CGFloat>] = [:]
        var edge = width
        for column in right.reversed() {
            ranges[column] = (edge - self.width(of: column))...edge
            edge -= self.width(of: column)
        }
        return Layout(label: label, graph: graph, commit: x...max(edge, x), author: ranges[.author], sha: ranges[.sha], date: ranges[.date])
    }

    /// Moves the boundary of `column` to `x`. Every column keeps its minimum, and the commit text keeps its own.
    mutating func drag(_ column: Column, to x: CGFloat, in width: CGFloat) {
        let layout = layout(in: width)
        let spare = max(layout.commit.upperBound - layout.commit.lowerBound - Column.commit.minimumWidth, 0)
        let current = self.width(of: column)
        let growth: CGFloat
        switch column {
        case .label, .graph:
            let edge = column == .label ? layout.label?.upperBound : layout.graph?.upperBound
            growth = x - (edge ?? x)
        default:
            let ranges: [Column: ClosedRange<CGFloat>?] = [.author: layout.author, .sha: layout.sha, .date: layout.date]
            growth = ((ranges[column] ?? nil)?.lowerBound ?? x) - x
        }
        let updated = max(min(current + growth, current + spare), column.minimumWidth)
        switch column {
        case .label: label = updated
        case .graph: graph = updated
        case .author: author = updated
        case .sha: sha = updated
        case .date: date = updated
        case .commit: break
        }
    }
}

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
