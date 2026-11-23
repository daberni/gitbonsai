import AppKit
import GitEngine
import GraphLayout

/// The history column of a repository tab: the column header, the virtualised table of rows, selection and navigation.
@MainActor
final class HistoryViewController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let view = NSView()
    let tableView = HistoryTableView()
    let columnsController: HistoryColumnsController
    private let observers = NotificationObservers()
    /// The row selected last; with several selected, the others are in `selectedRows`.
    var selectedRow = -1
    /// Several rows when commits are compared (⌘-click, ⇧-click); never the working directory among them.
    var selectedRows = IndexSet()
    /// The commit of the selected row. Rows are rebuilt before the table hears of it, so the index alone no longer names the commit then.
    var selectedID: String?
    /// The commits of the other selected rows, kept by ID for the same reason.
    var otherSelectedIDs: [String] = []
    /// While the table takes in new rows, its passing selections are no choice of the user's.
    var isApplyingRows = false
    private var multiSelection = HistoryMultiSelection()
    let toolTips = HistoryRowToolTips()
    private var isExtendingRange = false
    /// The selected commit, the others selected with it, and how far its row sat below the top of the visible area.
    struct Anchor {
        let id: String
        let others: [String]
        let offset: CGFloat
    }

    /// What a reload shows once it finished: the anchor to restore, or nil for the current row.
    var focusAfterReload: Anchor?
    /// Commits a rewrite replaced, by their old ID: the selection follows them to their new rows once the history is read again.
    var rewrittenCommits: [String: String] = [:]
    /// A reload asked to select HEAD once it finished.
    var headAfterReload = false
    /// A reload asked to bring the current row into view once it finished, since the action moved HEAD.
    var currentAfterReload = false
    let search: HistorySearchController
    private(set) weak var searchField: CommitSearchField?

    /// The selection changed; empty when nothing is selected.
    var onSelect: ((IndexSet) -> Void)?
    /// Double click on a row, while no other rows are selected, with the ref pill it hit, in the row or in its expanded labels.
    var onActivate: ((Int, PillRef?) -> Void)?
    /// Items for the context menu of a row.
    var menuItems: ((Int) -> [NSMenuItem])?
    /// Items for the context menu of one ref pill of a row, in the row and in its expanded labels.
    var pillMenuItems: ((Int, PillRef) -> [NSMenuItem])?

    let viewModel: GraphViewModel
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
        tableView.onCancel = { [weak self] in self?.cancel() ?? false }
        refOverlay.select = { [weak self] row in self?.select(row: row, scroll: false) }
        refOverlay.activate = { [weak self] row, pill in self?.onActivate?(row, pill) }
        refOverlay.menuItems = { [weak self] row in self?.menuItems?(row) ?? [] }
        refOverlay.pillMenuItems = { [weak self] row, ref in self?.pillMenuItems?(row, ref) ?? [] }
        columnsController.onChange = { [weak self] in self?.reloadVisibleRows() }
        tableView.onModifiedClick = { [weak self] row, flags in self?.extendSelection(to: row, flags: flags) ?? false }
        search.onChange = { [weak self] in
            self?.reloadVisibleRows()
            self?.updateSearchCounter()
        }
        search.selectedRow = { [weak self] in self?.selectedRow ?? -1 }
        observers.observe(AvatarStore.didChange) { [weak self] in self?.reloadVisibleRows() }
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
        // The working directory row sits at the top, possibly far above HEAD; the selection always ends up on screen.
        if row != headRow { tableView.scrollRowToVisible(row) }
    }

    /// Esc closes expanded labels; otherwise, without an active search, it goes back to where the work is: the working directory row when it has changes, else HEAD.
    private func cancel() -> Bool {
        if refOverlay.cancel() { return true }
        guard search.search == nil, let row = viewModel.currentRow else { return false }
        search.userSelected()
        select(row: row, scroll: true)
        return true
    }

    /// False while HEAD is not loaded.
    @discardableResult
    func selectHead() -> Bool {
        guard let head = viewModel.headSHA, let row = viewModel.rowIndex(of: head) else { return false }
        select(row: row, scroll: true)
        return true
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
        let point = NSApp.currentEvent.map { tableView.convert($0.locationInWindow, from: nil) }
        onActivate?(index, point.flatMap(refOverlay.pill(at:)))
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
        guard !isApplyingRows else { return }
        adoptTableSelection()
    }

    func adoptTableSelection() {
        let previous = selectedRows
        selectedRow = tableView.selectedRow
        selectedRows = tableView.selectedRowIndexes
        selectedID = viewModel.commits.indices.contains(selectedRow) ? viewModel.commits[selectedRow].id : nil
        otherSelectedIDs = selectedRows.filter { $0 != selectedRow && viewModel.commits.indices.contains($0) }.map { viewModel.commits[$0].id }
        // A choice made while a reload runs replaces what the reload would have restored.
        if selectedRow >= 0 {
            focusAfterReload = nil
            currentAfterReload = false
        }
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
