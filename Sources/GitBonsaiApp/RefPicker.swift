import AppKit
import GitEngine

/// Picks a branch, tag or commit: a `RefPickerButton` that opens a dropdown with a search field and the `RefCatalog`'s sections.
/// Typing filters and highlights, a typed SHA offers its commit, ↑ ↓ move, ⏎ picks and Esc closes. Any sheet or form that needs a start point or base can host one.
@MainActor
final class RefPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    private typealias R = Theme.RefPicker

    private enum Row {
        case header(RefCatalog.Section)
        case item(RefCatalog.Match)
    }

    let button = RefPickerButton()
    let search = TextInput(placeholder: "Branch, Tag oder SHA suchen")
    let table = NSTableView()
    private let scroll = NSScrollView()
    private let popover = NSPopover()
    private let repository: Repository
    private var catalog = RefCatalog(tips: [], current: [])
    private var rows: [Row] = []
    /// Each query starts a new SHA lookup; only the latest one may update the list.
    private var lookup = 0
    private var resolved: CommitSummary?

    private(set) var selection: RefCatalog.Item? {
        didSet { button.item = selection }
    }
    var onChange: ((RefCatalog.Item) -> Void)?

    var isOpen: Bool { popover.isShown }
    /// The window AppKit hosts the dropdown in, while it is open.
    var panelWindow: NSWindow? { isOpen ? search.window : nil }

    init(repository: Repository) {
        self.repository = repository
        super.init()
        button.onOpen = { [weak self] in self?.open() }
        buildPanel()
    }

    /// Replaces what the picker offers and chooses `selection`.
    func setCatalog(_ catalog: RefCatalog, selection: RefCatalog.Item?) {
        self.catalog = catalog
        self.selection = selection
    }

    // MARK: Panel

    private func buildPanel() {
        search.onChange = { [weak self] _ in self?.queryChanged() }
        search.onCommand = { [weak self] command in self?.handle(command) ?? false }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ref"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        // The popover's safe area would otherwise push the first section header under the search field.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero

        let content = NSView()
        for view in [search, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: R.rowHeight)
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: R.panelWidth),
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: R.panelPadding),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: R.panelPadding),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -R.panelPadding),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: R.panelPadding / 2),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: R.panelPadding / 2),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -R.panelPadding / 2),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -R.panelPadding / 2),
            scrollHeight,
        ])
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = !ScreenshotHarness.isActive
        popover.delegate = self
    }

    private var scrollHeight: NSLayoutConstraint!

    func open() {
        guard !popover.isShown, button.window != nil else { return }
        search.stringValue = ""
        resolved = nil
        reload(keepingSelection: true)
        button.isOpen = true
        guard let content = popover.contentViewController?.view else { return }
        content.layoutSubtreeIfNeeded()
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        search.window?.makeFirstResponder(search.field)
    }

    func close() {
        popover.close()
    }

    func popoverDidClose(_ notification: Notification) {
        button.isOpen = false
        button.window?.makeFirstResponder(button)
    }

    // MARK: Filtering

    private var query: String { search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func queryChanged() {
        lookup += 1
        let current = lookup
        let text = query
        resolved = nil
        reload(keepingSelection: false)
        guard RefCatalog.looksLikeSHA(text) else { return }
        Task {
            let commit = await repository.commitSummary(text)
            guard current == lookup, let commit else { return }
            resolved = commit
            reload(keepingSelection: false)
        }
    }

    /// Rebuilds the rows; selects the current choice when it is listed and asked for, otherwise the first item.
    private func reload(keepingSelection: Bool) {
        rows = catalog.groups(matching: query, resolved: resolved).flatMap { group in [Row.header(group.section)] + group.matches.map(Row.item) }
        table.reloadData()
        table.scroll(.zero)
        let chosen = keepingSelection ? rows.firstIndex { if case .item(let match) = $0 { match.item == selection } else { false } } : nil
        select(chosen ?? firstItem(from: 0, step: 1))
        let visible = min(rows.count, R.maxVisibleRows)
        let headers = rows.prefix(visible).filter { if case .header = $0 { true } else { false } }.count
        scrollHeight.constant = max(CGFloat(visible - headers) * R.rowHeight + CGFloat(headers) * R.headerHeight, R.rowHeight)
        if popover.isShown, let content = popover.contentViewController?.view {
            content.layoutSubtreeIfNeeded()
            popover.contentSize = content.fittingSize
        }
    }

    private func firstItem(from start: Int, step: Int) -> Int? {
        var index = start
        while rows.indices.contains(index) {
            if case .item = rows[index] { return index }
            index += step
        }
        return nil
    }

    private func select(_ index: Int?) {
        guard let index else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    // MARK: Keys

    private func handle(_ command: Selector) -> Bool {
        switch command {
        case #selector(NSResponder.moveDown(_:)):
            select(firstItem(from: table.selectedRow + 1, step: 1) ?? (table.selectedRow >= 0 ? table.selectedRow : nil))
        case #selector(NSResponder.moveUp(_:)):
            select(firstItem(from: table.selectedRow - 1, step: -1) ?? (table.selectedRow >= 0 ? table.selectedRow : nil))
        case #selector(NSResponder.insertNewline(_:)):
            pick(row: table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)):
            close()
        default:
            return false
        }
        return true
    }

    /// Chooses the item in `row` and closes the list.
    func pick(row: Int) {
        guard rows.indices.contains(row), case .item(let match) = rows[row] else { return }
        selection = match.item
        close()
        onChange?(match.item)
    }

    /// The items the list shows, in order, for the harness.
    var visibleItems: [(section: String, title: String, selected: Bool)] {
        var section = ""
        return rows.enumerated().compactMap { index, row in
            switch row {
            case .header(let value):
                section = RefItemStyle.sectionTitle(value)
                return nil
            case .item(let match):
                return (section, match.item.title, index == table.selectedRow)
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return R.headerHeight }
        return R.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .item = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PanelSelectionRowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = RefPickerRowView()
        switch rows[row] {
        case .header(let section): view.content = .header(RefItemStyle.sectionTitle(section))
        case .item(let match): view.content = .item(match)
        }
        view.onPress = { [weak self] in self?.pick(row: row) }
        return view
    }
}
