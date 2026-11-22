import AppKit
import GitEngine

/// The history column of a repository tab: the column header, the virtualised table of rows, selection and navigation.
@MainActor
final class HistoryViewController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let view = NSView()
    let tableView = HistoryTableView()
    let columnsController: HistoryColumnsController
    private(set) var selectedRow = -1

    /// The selection changed; nil when nothing is selected.
    var onSelect: ((Int?) -> Void)?
    /// Double click on a row.
    var onActivate: ((Int) -> Void)?
    /// Items for the context menu of a row.
    var menuItems: ((Int) -> [NSMenuItem])?

    private let viewModel: GraphViewModel
    private let header = HistoryHeaderView()
    private let guide = ColumnGuideView()

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
        columnsController = HistoryColumnsController(header: header, table: tableView, guide: guide)
        super.init()
        columnsController.onChange = { [weak self] in self?.reloadVisibleRows() }
        configureTable()
        layout()
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
            header.heightAnchor.constraint(equalToConstant: 30),
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
    }

    func rowsReset() {
        selectedRow = -1
        tableView.reloadData()
        onSelect?(nil)
    }

    func rowsShifted() {
        tableView.reloadData()
        columnsController.update(laneCount: viewModel.maxLaneCount)
    }

    /// Same commits, new HEAD: the selection follows the working tree and the newly checked-out commit is brought into view.
    func rowsRebuilt() {
        selectedRow = -1
        tableView.deselectAll(nil)
        tableView.reloadData()
        columnsController.update(laneCount: viewModel.maxLaneCount)
        selectCurrentRow(scrollToHead: true)
    }

    func metadataChanged() {
        reloadVisibleRows()
        if selectedRow < 0, !viewModel.isLoading { selectCurrentRow(scrollToHead: false) }
    }

    private func reloadVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: IndexSet(integer: 0))
    }

    // MARK: Selection and navigation

    func navigate(to sha: String) {
        guard let index = viewModel.rowIndex(of: sha) else { NSSound.beep(); return }
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

    /// Leaves a few rows of context above the target.
    private func scrollWithContext(to row: Int) {
        tableView.scrollRowToVisible(min(row + 6, viewModel.rows.count - 1))
        tableView.scrollRowToVisible(max(row - 3, 0))
    }

    /// Selects the next commit after the selection whose subject, author or SHA matches.
    func search(_ text: String) {
        let query = text.lowercased()
        guard !query.isEmpty else { return }
        let count = viewModel.commits.count
        for offset in 0..<count {
            let index = (selectedRow + 1 + offset) % count
            let commit = viewModel.commits[index]
            if commit.subject.lowercased().contains(query) || commit.authorName.lowercased().contains(query) || commit.id.hasPrefix(query) {
                select(row: index, scroll: true)
                return
            }
        }
        NSSound.beep()
    }

    @objc private func activateClickedRow(_ sender: Any?) {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : selectedRow
        guard index >= 0 else { return }
        onActivate?(index)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard tableView.clickedRow >= 0 else { return }
        menuItems?(tableView.clickedRow).forEach(menu.addItem)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { viewModel.rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let previous = selectedRow
        selectedRow = tableView.selectedRow
        let changed = IndexSet([previous, selectedRow].filter { $0 >= 0 && $0 < viewModel.rows.count })
        tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        onSelect?(selectedRow >= 0 ? selectedRow : nil)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard index < viewModel.rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? GraphRowView) ?? GraphRowView()
        view.identifier = identifier
        view.model = HistoryRowModel.make(row: index, in: viewModel, isSelected: index == selectedRow, columns: columnsController.columns)
        view.toolTip = viewModel.kinds[index] == .wip ? "Uncommittete Änderungen" : GraphRowView.exactFormatter.string(from: viewModel.commits[index].authorDate)
        return view
    }
}
