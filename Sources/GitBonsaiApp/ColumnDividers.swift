import AppKit

/// Column boundaries that can be dragged over a header or over the rows below it, shared by the history and the interactive rebase list.
@MainActor
enum ColumnDividers {
    /// Resize cursors over each boundary, `x` in the view's coordinates.
    static func addCursorRects(to view: NSView, at positions: [CGFloat]) {
        for x in positions { view.addCursorRect(NSRect(x: x - Theme.dragThreshold, y: 0, width: 2 * Theme.dragThreshold, height: view.bounds.height), cursor: .resizeLeftRight) }
    }

    /// The boundary within reach of `x`, if any.
    static func hit<Column>(_ x: CGFloat, in dividers: [(Column, CGFloat)]) -> Column? {
        dividers.first { abs($0.1 - x) <= Theme.dragThreshold }?.0
    }

    /// Follows the drag that started with a press on a boundary until the button comes up, reporting each position in the view's coordinates.
    /// A table would otherwise start its own row tracking, so the events are taken here.
    static func followDrag(in view: NSView, _ moved: (CGFloat) -> Void) {
        while let next = view.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            moved(view.convert(next.locationInWindow, from: nil).x)
        }
    }
}

/// A view laid over others in its own window that takes the pointer from what lies below, such as the expanded ref pills over the history rows.
/// Views outside the one asking count without the mark, such as the command bar over the whole window.
protocol PointerOverlay: NSView {}

/// Tracking areas and cursor rects react wherever their rectangle is, also under a view laid over them; hover effects ask here whether the pointer really reaches them.
@MainActor
enum PointerCover {
    /// True when the front-most view at the pointer is `view` or inside it. `throughOverlays` false also counts a `PointerOverlay` inside `view` as covering it.
    static func reaches(_ view: NSView, at locationInWindow: NSPoint, throughOverlays: Bool = false) -> Bool {
        guard let frame = view.window?.contentView?.superview else { return true }
        guard let hit = frame.hitTest(locationInWindow), hit.isDescendant(of: view) else { return false }
        guard !throughOverlays else { return true }
        var current: NSView? = hit
        while let candidate = current, candidate !== view {
            if candidate is PointerOverlay { return false }
            current = candidate.superview
        }
        return true
    }
}

/// The resize cursor over a column boundary, set as the pointer moves. Cursor rects would show it through anything laid over the boundary; this way an overlay keeps its own cursor.
@MainActor
final class DividerCursor {
    private var isShown = false

    func update(overDivider: Bool) {
        if overDivider {
            NSCursor.resizeLeftRight.set()
            isShown = true
        } else if isShown {
            NSCursor.arrow.set()
            isShown = false
        }
    }
}

/// A faint line over the whole height of a list at the column boundary under the mouse. It never takes clicks.
/// `positions` gives the boundaries for the view's width in its own coordinates; the owner calls `refresh()` when they change.
final class ColumnGuideView: NSView {
    var positions: (CGFloat) -> [CGFloat] = { _ in [] }
    private(set) var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The hovered boundary stays hovered while it is dragged, drawn at its new place.
    func refresh() {
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .enabledDuringMouseDrag], owner: self))
    }

    /// The guide takes no clicks itself, so whether the pointer reaches the list is asked of the view it lies over with its siblings.
    override func mouseMoved(with event: NSEvent) {
        guard let surface = superview, PointerCover.reaches(surface, at: event.locationInWindow) else {
            hovered = nil
            return
        }
        let x = convert(event.locationInWindow, from: nil).x
        hovered = positions(bounds.width).firstIndex { abs($0 - x) <= Theme.dragThreshold }
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let positions = positions(bounds.width)
        guard let hovered, positions.indices.contains(hovered) else { return }
        Theme.ink.withAlphaComponent(Theme.Wash.guide).setFill()
        NSRect(x: positions[hovered].rounded() - Theme.Stroke.strand / 2, y: 0, width: Theme.Stroke.strand, height: bounds.height).fill()
    }
}
