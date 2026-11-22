import AppKit
import GitEngine

/// The history column of a repository tab: the column header, the virtualised table of rows, selection and navigation.
@MainActor
final class HistoryViewController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let view = NSView()
    let tableView = HistoryTableView()
    let columnsController: HistoryColumnsController
    /// The row selected last; with several selected, the others are in `selectedRows`.
    private(set) var selectedRow = -1
    /// Several rows when commits are compared (⌘-click, ⇧-click); never the working directory among them.
    private(set) var selectedRows = IndexSet()
    /// The commit of the selected row. Rows are rebuilt before the table hears of it, so the index alone no longer names the commit then.
    private(set) var selectedID: String?
    private var multiSelection = HistoryMultiSelection()
    let toolTips = HistoryRowToolTips()
    private var isExtendingRange = false
    /// What a reload shows once it finished: the anchor to restore, or nil for the current row.
    private var focusAfterReload: Anchor?
    let search: HistorySearchController
    private(set) weak var searchField: CommitSearchField?

    /// The selection changed; empty when nothing is selected.
    var onSelect: ((IndexSet) -> Void)?
    /// Double click on a row, while no other rows are selected.
    var onActivate: ((Int) -> Void)?
    /// Items for the context menu of a row.
    var menuItems: ((Int) -> [NSMenuItem])?

    private let viewModel: GraphViewModel
    private let header = HistoryHeaderView()
    private let guide = ColumnGuideView()
    /// Expands a row's ref pills that the label column cuts off.
    let refOverlay: RefOverlayController

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
        columnsController = HistoryColumnsController(header: header, table: tableView, guide: guide)
        search = HistorySearchController(viewModel: viewModel)
        refOverlay = RefOverlayController(table: tableView)
        super.init()
        refOverlay.select = { [weak self] row in self?.select(row: row, scroll: false) }
        refOverlay.activate = { [weak self] row in self?.onActivate?(row) }
        refOverlay.menuItems = { [weak self] row in self?.menuItems?(row) ?? [] }
        columnsController.onChange = { [weak self] in self?.reloadVisibleRows() }
        tableView.onModifiedClick = { [weak self] row, flags in self?.extendSelection(to: row, flags: flags) ?? false }
        search.onChange = { [weak self] in
            self?.reloadVisibleRows()
            self?.updateSearchCounter()
        }
        search.selectedRow = { [weak self] in self?.selectedRow ?? -1 }
        NotificationCenter.default.addObserver(forName: AvatarStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadVisibleRows() }
        }
        // Selecting through the table leaves the search field first responder, so typing goes on.
        search.onJump = { [weak self] row in self?.select(row: row, scroll: true) }
        configureTable()
        layout()
        // Tooltip rects do not follow a resize; the columns right of the commit text move with the width.
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(tableResized(_:)), name: NSView.frameDidChangeNotification, object: tableView)
    }

    @objc private func tableResized(_ notification: Notification) {
        let visible = tableView.rows(in: tableView.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            guard let view = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? GraphRowView, let model = view.model else { continue }
            toolTips.install(on: view, model: model, width: tableView.bounds.width)
        }
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Theme.Graph.rowHeight
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = Theme.surface0
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = true
        tableView.gridStyleMask = []
        tableView.target = self
        tableView.doubleAction = #selector(activateClickedRow(_:))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        let column = NSTableColumn(identifier: .init("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    }

    private func layout() {
        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface0
        for subview in [header, scroll, guide] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.Window.columnHeader),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            guide.topAnchor.constraint(equalTo: view.topAnchor),
            guide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            guide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: Changes from the view model

    func rowsAppended(_ range: Range<Int>) {
        tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
        if range.lowerBound > 0 { tableView.reloadData(forRowIndexes: IndexSet(integer: range.lowerBound - 1), columnIndexes: IndexSet(integer: 0)) }
        columnsController.update(laneCount: viewModel.maxLaneCount)
        search.commitsAppended()
    }

    /// A reload that a later refresh restarted keeps the anchor of the first one, since nothing was selected in between.
    func rowsReset(focus: GraphViewModel.Focus) {
        if focus == .current {
            focusAfterReload = nil
        } else if let anchor = anchor() {
            focusAfterReload = anchor
        }
        selectedRow = -1
        selectedRows = []
        selectedID = nil
        tableView.reloadData()
        search.historyChanged()
        onSelect?([])
    }

    func rowsShifted() {
        tableView.reloadData()
        columnsController.update(laneCount: viewModel.maxLaneCount)
        search.historyChanged()
    }

    /// The rows were laid out again after a write. The selected commit stays where it was on screen unless the focus moves to the current row or the commit left the history.
    func rowsRebuilt(focus: GraphViewModel.Focus) {
        let kept = focus == .keepSelection ? anchor() : nil
        selectedRow = -1
        selectedRows = []
        selectedID = nil
        tableView.deselectAll(nil)
        tableView.reloadData()
        columnsController.update(laneCount: viewModel.maxLaneCount)
        search.historyChanged()
        if !restore(kept) { selectCurrentRow(scrollToHead: true) }
    }

    func metadataChanged() {
        search.refsMayHaveChanged()
        reloadVisibleRows()
        guard selectedRow < 0, !viewModel.isLoading else { return }
        let anchor = focusAfterReload
        focusAfterReload = nil
        if !restore(anchor) { selectCurrentRow(scrollToHead: anchor != nil) }
    }

    // MARK: Keeping the selection

    /// The selected commit, the others selected with it, and how far its row sat below the top of the visible area.
    private struct Anchor {
        let id: String
        let others: [String]
        let offset: CGFloat
    }

    private func anchor() -> Anchor? {
        guard let selectedID, selectedRow >= 0 else { return nil }
        let others = selectedRows.filter { $0 != selectedRow && viewModel.commits.indices.contains($0) }.map { viewModel.commits[$0].id }
        return Anchor(id: selectedID, others: others, offset: tableView.rect(ofRow: selectedRow).minY - tableView.visibleRect.minY)
    }

    /// Selects the anchored commits again and scrolls so that the anchor's row sits where it sat before. False when that commit is no longer in the history; others that left stay unselected.
    private func restore(_ anchor: Anchor?) -> Bool {
        guard let anchor, let row = viewModel.rowIndex(of: anchor.id) else { return false }
        let others = IndexSet(anchor.others.compactMap { viewModel.rowIndex(of: $0) })
        // One change for all rows: a passing selection of fewer rows would count as navigation.
        tableView.selectRowIndexes(others.union(IndexSet(integer: row)), byExtendingSelection: false)
        guard let clip = tableView.enclosingScrollView?.contentView else { return true }
        let maxY = max(tableView.bounds.height - clip.bounds.height, 0)
        let y = min(max(tableView.rect(ofRow: row).minY - anchor.offset, 0), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        return true
    }

    private func reloadVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: Selection and navigation

    func navigate(to sha: String) {
        guard let index = viewModel.rowIndex(of: sha) else { NSSound.beep(); return }
        search.userSelected()
        select(row: index, scroll: true)
    }

    /// Selects the uncommitted changes when there are any, otherwise HEAD. The changes sit in the first row, so HEAD is scrolled to separately.
    func selectCurrentRow(scrollToHead: Bool) {
        guard let row = viewModel.currentRow else { return }
        select(row: row, scroll: false)
        guard scrollToHead, let head = viewModel.headSHA, let headRow = viewModel.rowIndex(of: head) else { return }
        scrollWithContext(to: headRow)
    }

    func select(row: Int, scroll: Bool) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scroll { scrollWithContext(to: row) }
    }

    /// Read from the click's own flags, so the harness's synthesized clicks select the same way as real ones.
    private func extendSelection(to row: Int, flags: NSEvent.ModifierFlags) -> Bool {
        guard let rows = multiSelection.rows(afterClickOn: row, flags: flags, selected: tableView.selectedRowIndexes, lastSelected: selectedRow, wipRow: viewModel.kinds.firstIndex(of: .wip)) else { return true }
        search.userSelected()
        isExtendingRange = true
        tableView.selectRowIndexes(rows, byExtendingSelection: false)
        isExtendingRange = false
        return true
    }

    /// Leaves a few rows of context above the target.
    private func scrollWithContext(to row: Int) {
        tableView.scrollRowToVisible(min(row + 6, viewModel.rows.count - 1))
        tableView.scrollRowToVisible(max(row - 3, 0))
    }

    // MARK: Search

    /// The field drives the search; its counter follows the matches and the selection.
    func connect(searchField field: CommitSearchField) {
        searchField = field
        field.onChange = { [weak self] text in
            self?.search.setQuery(text)
            self?.updateSearchCounter()
        }
        field.onStep = { [weak self] forward in self?.stepSearch(forward: forward) }
    }

    /// Selects the next or previous match; without matches the counter already says so.
    func stepSearch(forward: Bool) {
        guard let row = search.step(from: selectedRow, forward: forward) else { return }
        search.userSelected()
        select(row: row, scroll: true)
    }

    private func updateSearchCounter() {
        searchField?.counterText = search.counter(selectedRow: selectedRow)
    }

    /// While several rows are selected a double click only adds to the comparison: ⌘-clicking quickly must not check anything out.
    @objc private func activateClickedRow(_ sender: Any?) {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : selectedRow
        guard index >= 0, selectedRows.count <= 1 else { return }
        onActivate?(index)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard tableView.clickedRow >= 0 else { return }
        menuItems?(tableView.clickedRow).forEach(menu.addItem)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { viewModel.rows.count }

    /// Asked for clicks and arrow keys only, not for selections made in code. The working directory is no commit to compare, so it leaves a selection of several rows.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        search.userSelected()
        guard proposed.count > 1, let wip = viewModel.kinds.firstIndex(of: .wip) else { return proposed }
        var rows = proposed
        rows.remove(wip)
        return rows
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let previous = selectedRows
        selectedRow = tableView.selectedRow
        selectedRows = tableView.selectedRowIndexes
        selectedID = viewModel.commits.indices.contains(selectedRow) ? viewModel.commits[selectedRow].id : nil
        // A choice made while a reload runs replaces what the reload would have restored.
        if selectedRow >= 0 { focusAfterReload = nil }
        if !isExtendingRange { multiSelection.anchor = selectedRow >= 0 ? selectedRow : nil }
        let changed = previous.symmetricDifference(selectedRows).filteredIndexSet { $0 < viewModel.rows.count }
        tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        updateSearchCounter()
        onSelect?(selectedRows)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard index < viewModel.rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? GraphRowView) ?? GraphRowView()
        view.identifier = identifier
        view.model = HistoryRowModel.make(row: index, in: viewModel, isSelected: selectedRows.contains(index), columns: columnsController.columns, search: search)
        if let model = view.model { toolTips.install(on: view, model: model, width: tableView.bounds.width) }
        return view
    }
}
