import AppKit

/// The sidebar's outline: one full-width column without the outline's own disclosure triangles, since the rows draw their chevrons on the sidebar's grid.
/// Adds what a source list answers to from the keyboard: space acts like a click, ⏎ like a double click, ⌃⏎ opens the row's menu.
final class SidebarOutlineView: NSOutlineView {
    /// A click (`primary`) or a double click on the row.
    var onActivate: ((_ row: Int, _ primary: Bool) -> Void)?
    /// The menu of the row, for the keyboard and VoiceOver.
    var onShowMenu: ((_ row: Int) -> Void)?

    /// Width the rows are laid out in: the visible width a legacy scroller leaves, whether or not a scroller shows and in either style.
    /// Expanding a section, resizing the window or changing "Show scroll bars" never moves the right edge, and an overlay scroller lies in the gutter instead of on the slots.
    var contentWidth: CGFloat {
        guard let scrollView = enclosingScrollView else { return bounds.width }
        let reserved = NSScrollView.contentSize(forFrameSize: scrollView.frame.size, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self, borderType: scrollView.borderType, controlSize: scrollView.verticalScroller?.controlSize ?? .regular, scrollerStyle: .legacy)
        return min(bounds.width, reserved.width)
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }

    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        let rowRect = rect(ofRow: row)
        return NSRect(x: 0, y: rowRect.minY, width: bounds.width, height: rowRect.height)
    }

    /// The context menu of a row; nil for none.
    var menuForRow: ((_ row: Int) -> NSMenu?)?

    /// Builds the menu without the table's own handling, which frames the clicked row in the system's blue; the sidebar marks the row itself.
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return row >= 0 ? menuForRow?(row) : nil
    }

    /// Like Finder's sidebar, a click acts even when it also brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard selectedRow >= 0 else { return super.keyDown(with: event) }
        switch (event.keyCode, modifiers.subtracting(.numericPad)) {
        case (KeyCode.space, []):
            onActivate?(selectedRow, true)
        case (KeyCode.return, []), (KeyCode.keypadEnter, []):
            onActivate?(selectedRow, false)
        case (KeyCode.return, [.control]):
            onShowMenu?(selectedRow)
        default:
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard selectedRow >= 0, let onShowMenu else { return super.accessibilityPerformShowMenu() }
        onShowMenu(selectedRow)
        return true
    }
}
