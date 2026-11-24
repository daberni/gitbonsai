import AppKit
import GitEngine

/// The repository sidebar, drawn on one five-column grid: expander, icon, text, value, status slot.
///
/// Left of the text there is only hierarchy; everything that describes state (counters, ahead/behind, the checked-out mark, the worktree glyph) sits on the right.
final class SidebarView: NSView {
    typealias M = Theme.Sidebar

    var onSelectCommit: ((String) -> Void)?
    /// Double click on a branch. `worktreePath` is set when the branch is checked out in another worktree.
    var onCheckout: ((CheckoutTarget, _ worktreePath: String?) -> Void)?
    /// Double click on a worktree other than the one shown.
    var onSwitchWorktree: ((String) -> Void)?
    /// The Tags or Stashes row was clicked; `anchor` is the row's rectangle in this view, for a popover.
    var onOpenPanel: ((SidebarPanel, NSRect) -> Void)?
    /// The plus on the Local header.
    var onNewBranch: (() -> Void)?
    /// The plus on the Worktrees header.
    var onNewWorktree: (() -> Void)?
    var onAddRemote: (() -> Void)?
    /// The configured remotes, so that one without fetched branches still shows.
    var remotes: [String] = []
    /// The entries of a row's context menu.
    var menuItems: ((SidebarMenuSubject) -> [NSMenuItem])?

    var items: [SidebarItem] = []
    var frames: [CGRect] = []
    var outline = SidebarOutline()
    /// The repository whose collapsed sections `outline` holds; another one restores its own.
    private var outlinePath: String?
    var hovered: Int?
    private lazy var pointer: ListHover = {
        let hover = ListHover(view: self)
        hover.onChange = { [weak self] in self?.pointerChanged($0) }
        return hover
    }()
    /// Bottom of the last row; taller than the visible area when the sidebar scrolls.
    private(set) var contentHeight: CGFloat = 0
    private(set) weak var model: GraphViewModel?

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointer.attach()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview else { return }
        // A taller visible area needs a taller view, or the rows below the content stop taking clicks and hover.
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func visibleAreaChanged() {
        if !items.isEmpty { layoutItems() }
    }

    /// Width the rows are laid out in: the visible width a legacy scroller leaves, whether or not a scroller shows and in either style.
    /// Expanding a section, resizing the window or changing "Show scroll bars" never moves the right edge, and an overlay scroller lies in the gutter instead of on the slots.
    var contentWidth: CGFloat {
        guard let scrollView = enclosingScrollView else { return bounds.width }
        let reserved = NSScrollView.contentSize(forFrameSize: scrollView.frame.size, horizontalScrollerClass: nil, verticalScrollerClass: NSScroller.self, borderType: scrollView.borderType, controlSize: scrollView.verticalScroller?.controlSize ?? .regular, scrollerStyle: .legacy)
        return min(bounds.width, reserved.width)
    }

    /// Right edge of the status slot column.
    var slotRight: CGFloat { contentWidth - M.rowInset - Theme.Space.xs }

    /// Right edge of the counts and other values left of the slot.
    var valueRight: CGFloat { slotRight - M.slot - M.textGap }

    func reload(from model: GraphViewModel) {
        self.model = model
        let path = model.repository.path
        if path != outlinePath {
            outlinePath = path
            outline = SidebarOutline(state: SessionStore.standard().sidebarState(for: path) ?? OutlineState())
        }
        items = outline.items(from: model, remotes: remotes)
        layoutItems()
    }

    /// Collapses or expands a section or folder and remembers it for the next launch.
    func toggle(_ key: String) {
        guard let model else { return }
        outline.toggle(key)
        saveOutline()
        reload(from: model)
    }

    func saveOutline() {
        if let outlinePath { SessionStore.standard().saveSidebarState(outline.state, for: outlinePath) }
    }

    private func layoutItems() {
        var y = Theme.Space.s
        frames = items.map { item in
            let height: CGFloat
            switch item {
            case .header: y += Theme.Space.xs; height = M.headerHeight
            case .worktree: height = M.worktreeHeight
            case .row: height = M.rowHeight
            }
            defer { y += height }
            return CGRect(x: M.rowInset, y: y, width: contentWidth - 2 * M.rowInset, height: height)
        }
        contentHeight = y + Theme.Space.s
        let total = max(contentHeight, enclosingScrollView?.contentSize.height ?? 0)
        if frame.height != total { setFrameSize(NSSize(width: frame.width, height: total)) }
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, !items.isEmpty { layoutItems() }
    }

    // MARK: Interaction

    private func index(at point: CGPoint) -> Int? {
        frames.firstIndex { $0.contains(point) }
    }

    /// Follows the pointer, also while the sidebar scrolls under a still pointer.
    private func pointerChanged(_ point: CGPoint?) {
        let new = point.flatMap(index(at:))
        if new != hovered { hovered = new; needsDisplay = true }
    }

    /// Like Finder's sidebar, a click acts even when it also brings the window forward. Harness clicks rely on it: a background window never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let index = index(at: convert(event.locationInWindow, from: nil)), model != nil else { return }
        switch items[index] {
        case .header(let key, _, _, _, let plus):
            if plus, plusRect(in: frames[index]).contains(convert(event.locationInWindow, from: nil)) {
                if key == "local" { onNewBranch?() } else if key == "worktrees" { onNewWorktree?() }
                return
            }
            toggle(key)
        case .worktree(let info, let isCurrent):
            // Same as a branch row: one click shows where it stands in the history, a double click goes there.
            if event.clickCount == 2, !isCurrent, !info.worktree.isPrunable, !info.worktree.isBare {
                onSwitchWorktree?(info.worktree.path)
            } else if let head = info.worktree.headSHA {
                onSelectCommit?(head)
            }
        case .row(let row):
            guard let target = row.target else { break }
            if target == SidebarItem.addRemoteTarget {
                onAddRemote?()
            } else if event.clickCount == 2, let checkout = row.checkout {
                onCheckout?(checkout, row.linkedWorktree)
            } else if let panel = SidebarPanel(target: target) {
                onOpenPanel?(panel, frames[index])
            } else if target.hasPrefix("folder:") {
                toggle(String(target.dropFirst("folder:".count)))
            } else {
                onSelectCommit?(target)
            }
        }
    }

    /// The status slot of a header, where its plus is drawn, with a little room around it for the click.
    private func plusRect(in rect: CGRect) -> CGRect {
        CGRect(x: slotRight - M.slot, y: rect.midY - M.slot / 2, width: M.slot, height: M.slot).insetBy(dx: -Theme.Space.xs, dy: -Theme.Space.xs)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let index = index(at: convert(event.locationInWindow, from: nil)) else { return nil }
        return menu(forItemAt: index)
    }

    /// The row whose menu the harness asks for, by `SidebarMenuSubject.harnessName`.
    func itemIndex(named name: String) -> Int? {
        items.firstIndex { $0.menuSubject?.harnessName == name }
    }

    func itemIndex(header key: String) -> Int? {
        items.firstIndex { if case .header(key, _, _, _, _) = $0 { true } else { false } }
    }

    func rowRect(at index: Int) -> CGRect { frames[index] }

    func menu(forItemAt index: Int) -> NSMenu? {
        guard let subject = items[index].menuSubject, let entries = menuItems?(subject), !entries.isEmpty else { return nil }
        let menu = NSMenu()
        entries.forEach(menu.addItem)
        return menu
    }

    /// The worktree path linked to the hovered row: a branch checked out elsewhere, or the worktree row itself.
    var hoveredWorktreePath: String? {
        guard let hovered, hovered < items.count else { return nil }
        switch items[hovered] {
        case .row(let row): return row.linkedWorktree
        case .worktree(let info, let isCurrent): return isCurrent ? nil : info.worktree.path
        default: return nil
        }
    }
}
