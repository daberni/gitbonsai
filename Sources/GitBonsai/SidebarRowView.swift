import AppKit

/// The backgrounds of a sidebar row: the checked-out branch and the current worktree, the hover, the worktree a hovered branch is checked out in, and the selection.
final class SidebarRowView: NSTableRowView {
    private typealias M = Theme.Sidebar
    static let identifier = NSUserInterfaceItemIdentifier("SidebarRow")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
    }

    required init?(coder: NSCoder) { nil }

    enum Mark {
        case none
        /// The checked-out branch or the worktree this window shows.
        case current
    }

    var mark: Mark = .none { didSet { if mark != oldValue { needsDisplay = true } } }
    /// Only rows that do something on a click take the hover.
    var takesHover = false
    var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    /// The row's context menu is open.
    var isMenuTarget = false { didSet { if isMenuTarget != oldValue { needsDisplay = true } } }
    /// A hovered branch is checked out in this row's worktree.
    var isLinkHighlighted = false { didSet { if isLinkHighlighted != oldValue { needsDisplay = true } } }
    /// Room above the content that the background leaves out, as above a header.
    var topGap: CGFloat = 0

    override var isSelected: Bool { didSet { needsDisplay = true } }
    override var isEmphasized: Bool { didSet { needsDisplay = true } }

    private var backgroundRect: CGRect {
        let width = (superview as? SidebarOutlineView)?.contentWidth ?? bounds.width
        return CGRect(x: M.rowInset, y: topGap, width: min(bounds.width, width) - 2 * M.rowInset, height: bounds.height - topGap)
    }

    private func fill(_ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: backgroundRect, xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm).fill()
    }

    override func drawBackground(in dirtyRect: NSRect) {
        if mark == .current {
            fill(Theme.surfaceSelected)
        } else if isLinkHighlighted {
            fill(Theme.claySoft)
            Theme.clay.setStroke()
            let outline = NSBezierPath(roundedRect: backgroundRect.insetBy(dx: Theme.Stroke.icon / 2, dy: Theme.Stroke.icon / 2), xRadius: Theme.Radius.sm, yRadius: Theme.Radius.sm)
            outline.lineWidth = Theme.Stroke.icon
            outline.stroke()
        } else if isMenuTarget || (isHovered && takesHover && !isSelected) {
            fill(Theme.surface2)
        }
    }

    /// Like a native source list: strong while the sidebar has the keyboard focus, faint otherwise.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        fill(Theme.sky.withAlphaComponent(isEmphasized ? Theme.Wash.guide : Theme.Wash.pressed))
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}
