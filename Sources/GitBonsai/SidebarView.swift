import AppKit
import GitEngine

/// The repository sidebar: worktrees, tags, local branches with the working directory and stashes, and the remotes, as a view-based outline.
/// It keeps which sections and folders are collapsed per repository, and routes clicks, double clicks and keys to the tab.
final class SidebarView: NSView {
    private typealias M = Theme.Sidebar

    var onSelectCommit: ((String) -> Void)?
    /// Double click on a branch. `worktreePath` is set when the branch is checked out in another worktree.
    var onCheckout: ((CheckoutTarget, _ worktreePath: String?) -> Void)?
    /// Double click on a worktree other than the one shown.
    var onSwitchWorktree: ((String) -> Void)?
    /// The Tags or Stashes row was clicked; `anchor` is the row's rectangle in `outlineView`, which a popover follows while the sidebar scrolls.
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

    let outlineView = SidebarOutlineView()
    let scrollView = NSScrollView()
    private(set) var roots: [SidebarNode] = []
    private(set) var outline = SidebarOutline()
    /// The repository whose collapsed sections `outline` holds; another one restores its own.
    private var outlinePath: String?
    /// Remembers which groups are open, per repository.
    private let sessions: SessionStore
    private(set) weak var model: GraphViewModel?
    /// Set while `reload` and `reveal` restore the selection, which the history must not follow.
    private var isRestoring = false
    private lazy var pointer: ListHover = {
        let hover = ListHover(view: outlineView)
        hover.onChange = { [weak self] _ in self?.updateHover() }
        return hover
    }()
    /// The row whose context menu is open; it keeps the hover wash until the menu closes.
    private var menuRow = -1
    /// The item the user collapses; the outline also reports its open descendants as collapsed, which must stay open in the stored state.
    private var collapsingItem: SidebarNode?

    init(sessions: SessionStore) {
        self.sessions = sessions
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.style = .plain
        outlineView.rowSizeStyle = .custom
        outlineView.intercellSpacing = .zero
        outlineView.indentationPerLevel = 0
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outlineView.backgroundColor = Theme.surface1
        outlineView.focusRingType = .none
        outlineView.allowsEmptySelection = true
        outlineView.autosaveExpandedItems = false
        outlineView.setAccessibilityLabel(String(localized: "sidebar.accessibility.label", defaultValue: "Sidebar", bundle: .module, comment: "VoiceOver name of the repository sidebar."))
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(clicked)
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.onActivate = { [weak self] row, primary in self?.activate(row: row, primary: primary) }
        outlineView.onShowMenu = { [weak self] row in self?.showMenu(forRow: row) }
        outlineView.menuForRow = { [weak self] row in self?.contextMenu(forRow: row) }

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.surface1
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: Theme.Space.s, left: 0, bottom: Theme.Space.s, right: 0)
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointer.attach()
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    func node(atRow row: Int) -> SidebarNode? {
        row >= 0 ? outlineView.item(atRow: row) as? SidebarNode : nil
    }

    func row(of id: String) -> Int? {
        (0..<outlineView.numberOfRows).first { node(atRow: $0)?.id == id }
    }

    // MARK: Loading

    func reload(from model: GraphViewModel) {
        self.model = model
        let path = model.repository.path
        if path != outlinePath {
            outlinePath = path
            outline = SidebarOutline(state: sessions.sidebarState(for: path) ?? OutlineState())
        }
        let selectedID = node(atRow: outlineView.selectedRow)?.id
        roots = outline.nodes(from: SidebarContent(model: model, remotes: remotes))
        whileRestoring {
            outlineView.reloadData()
            expandOpenChildren(of: nil)
            if let selectedID, let row = row(of: selectedID) {
                outlineView.selectRowIndexes([row], byExtendingSelection: false)
            }
        }
        updateHover()
    }

    /// Expands what the stored state has open below `parent`, which the outline shows expanded already.
    private func expandOpenChildren(of parent: SidebarNode?) {
        for node in parent?.children ?? roots {
            guard let key = node.expansionKey, !outline.isCollapsed(key) else { continue }
            outlineView.expandItem(node)
        }
    }

    /// Collapses or expands a section or folder; the outline's notifications remember it for the next launch.
    func toggle(_ node: SidebarNode) {
        guard node.isExpandable else { return }
        if outlineView.isItemExpanded(node) { outlineView.collapseItem(node) } else { outlineView.expandItem(node) }
    }

    private func expansionChanged(_ notification: Notification, collapsed: Bool) {
        guard let node = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0 { (outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCellView)?.isExpanded = !collapsed }
        if collapsed {
            guard collapsingItem === node else { return }
            collapsingItem = nil
        } else {
            expandOpenChildren(of: node)
        }
        // Expanding what the stored state has open changes nothing in it, so nothing is saved then.
        guard let key = node.expansionKey, outline.setCollapsed(key, collapsed), let outlinePath else { return }
        sessions.saveSidebarState(outline.state, for: outlinePath)
    }

    private func whileRestoring(_ restore: () -> Void) {
        isRestoring = true
        defer { isRestoring = false }
        restore()
    }

    // MARK: Reveal

    /// Expands the section and folder that hold the target, selects its row and scrolls it into view. Tags and stashes live in their panels, not in the tree, so nothing happens for them.
    func reveal(_ target: RefJump.Target) {
        guard let model, let id = outline.expand(toShow: target) else { return }
        if let outlinePath { sessions.saveSidebarState(outline.state, for: outlinePath) }
        reload(from: model)
        guard let row = row(of: id) else { return }
        whileRestoring { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
        outlineView.scrollRowToVisible(row)
    }

    // MARK: Actions

    @objc private func clicked() {
        activate(row: outlineView.clickedRow, primary: true)
    }

    @objc private func doubleClicked() {
        guard let node = node(atRow: outlineView.clickedRow) else { return }
        performSecondary(node)
    }

    /// A click or space does the row's own thing; a double click or ⏎ goes there: checks out, switches worktree. ⏎ on a row without such an action does what a click does.
    private func activate(row: Int, primary: Bool) {
        guard let node = node(atRow: row) else { return }
        if primary || !performSecondary(node) { performPrimary(node, row: row) }
    }

    private func performPrimary(_ node: SidebarNode, row: Int) {
        switch node.item {
        case .header:
            toggle(node)
        case .worktree(let info, _):
            // Same as a branch row: one click shows where it stands in the history, a double click goes there.
            if let head = info.worktree.headSHA { onSelectCommit?(head) }
        case .row(let entry):
            guard let target = entry.target else { break }
            if target == SidebarItem.addRemoteTarget {
                onAddRemote?()
            } else if let panel = SidebarPanel(target: target) {
                onOpenPanel?(panel, anchor(ofRow: row))
            } else if node.isExpandable {
                toggle(node)
            } else {
                onSelectCommit?(target)
            }
        }
    }

    @discardableResult
    private func performSecondary(_ node: SidebarNode) -> Bool {
        switch node.item {
        case .worktree(let info, let isCurrent):
            guard !isCurrent, !info.worktree.isPrunable, !info.worktree.isBare else { return false }
            onSwitchWorktree?(info.worktree.path)
            return true
        case .row(let row):
            guard let checkout = row.checkout else { return false }
            onCheckout?(checkout, row.linkedWorktree)
            return true
        case .header:
            return false
        }
    }

    /// The row's background in the outline's coordinates, where a popover points.
    private func anchor(ofRow row: Int) -> NSRect {
        let rect = outlineView.rect(ofRow: row)
        return NSRect(x: M.rowInset, y: rect.minY, width: outlineView.contentWidth - 2 * M.rowInset, height: rect.height)
    }

    @objc private func plusClicked(_ sender: PlusButton) {
        let row = outlineView.row(for: sender)
        guard case .header(let key, _, _, _, _) = node(atRow: row)?.item else { return }
        if key == "local" { onNewBranch?() } else if key == "worktrees" { onNewWorktree?() }
    }

    // MARK: Menus

    private func menuEntries(forRow row: Int) -> [NSMenuItem] {
        guard let subject = node(atRow: row)?.item.menuSubject else { return [] }
        return menuItems?(subject) ?? []
    }

    /// The row's menu, which marks the row while it is open.
    private func contextMenu(forRow row: Int) -> NSMenu? {
        let entries = menuEntries(forRow: row)
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        entries.forEach(menu.addItem)
        menu.delegate = self
        menuRow = row
        updateHover()
        return menu
    }

    /// Opens the row's menu below the row, for ⌃⏎ and VoiceOver.
    private func showMenu(forRow row: Int) {
        guard let menu = contextMenu(forRow: row) else { return }
        let rect = outlineView.rect(ofRow: row)
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX + M.rowInset, y: rect.maxY), in: outlineView)
    }

    // MARK: Hover

    /// The row under the pointer, also while the sidebar scrolls under a still pointer; -1 for none.
    private var hoveredRow: Int {
        pointer.point.map { outlineView.row(at: $0) } ?? -1
    }

    /// The worktree path linked to the hovered row: a branch checked out elsewhere, or the worktree row itself.
    private var hoveredWorktreePath: String? {
        switch node(atRow: hoveredRow)?.item {
        case .row(let row): row.linkedWorktree
        case .worktree(let info, let isCurrent): isCurrent ? nil : info.worktree.path
        default: nil
        }
    }

    private func updateHover() {
        let linked = hoveredWorktreePath
        outlineView.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? SidebarRowView else { return }
            rowView.isHovered = row == hoveredRow
            rowView.isMenuTarget = row == menuRow
            rowView.isLinkHighlighted = linked != nil && { if case .worktree(let info, _) = node(atRow: row)?.item { info.worktree.path == linked } else { false } }()
        }
    }
}

extension SidebarView: NSOutlineViewDataSource {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isExpandable ?? false
    }
}

extension SidebarView: NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: SidebarCellView.identifier, owner: nil) as? SidebarCellView ?? {
            let cell = SidebarCellView()
            cell.plusButton.target = self
            cell.plusButton.action = #selector(plusClicked)
            return cell
        }()
        cell.show(node, expanded: outlineView.isItemExpanded(node))
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? SidebarNode else { return nil }
        let rowView = outlineView.makeView(withIdentifier: SidebarRowView.identifier, owner: nil) as? SidebarRowView ?? SidebarRowView()
        rowView.topGap = 0
        switch node.item {
        case .header:
            rowView.mark = .none
            rowView.takesHover = false
            rowView.topGap = Theme.Space.xs
        case .worktree(_, let isCurrent):
            rowView.mark = isCurrent ? .current : .none
            rowView.takesHover = true
        case .row(let row):
            rowView.mark = row.isCheckedOut ? .current : .none
            rowView.takesHover = row.target != nil || row.slot == .chevronRight
        }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? SidebarRowView else { return }
        rowView.isHovered = row == hoveredRow
        rowView.isMenuTarget = row == menuRow
        if let linked = hoveredWorktreePath, case .worktree(let info, _) = node(atRow: row)?.item { rowView.isLinkHighlighted = info.worktree.path == linked } else { rowView.isLinkHighlighted = false }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? SidebarNode)?.item {
        case .header: M.headerHeight + Theme.Space.xs
        case .worktree: M.worktreeHeight
        default: M.rowHeight
        }
    }

    /// Headers take the selection from the keyboard, so arrows can reach and fold them, but not from a click, which only folds them.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard case .header = (item as? SidebarNode)?.item else { return true }
        return NSApp.currentEvent?.type == .keyDown || isRestoring
    }

    /// Moving through branches and worktrees with the arrow keys or type-select shows each in the history, as a click does.
    /// A click on a row shows it again through `clicked()`, which also covers a click on the row already selected.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoring, let node = node(atRow: outlineView.selectedRow) else { return }
        switch node.item {
        case .worktree(let info, _):
            if let head = info.worktree.headSHA { onSelectCommit?(head) }
        case .row(let row):
            if let target = row.target, row.ref != nil || target == GraphViewModel.wipID || target == model?.headSHA, !node.isExpandable { onSelectCommit?(target) }
        case .header:
            break
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        switch (item as? SidebarNode)?.item {
        case .header(_, let title, _, _, _): title
        case .worktree(let info, _): (info.worktree.path as NSString).lastPathComponent
        case .row(let row): row.text
        case nil: nil
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        expansionChanged(notification, collapsed: false)
    }

    func outlineViewItemWillCollapse(_ notification: Notification) {
        if collapsingItem == nil { collapsingItem = notification.userInfo?["NSObject"] as? SidebarNode }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        expansionChanged(notification, collapsed: true)
    }
}

extension SidebarView: NSMenuDelegate {
    func menuDidClose(_ menu: NSMenu) {
        menuRow = -1
        updateHover()
    }
}
