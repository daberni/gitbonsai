import AppKit

/// One entry of a sidebar panel: two lines, a glyph on the left and the age and short SHA on the right.
struct PanelRow: Equatable {
    let id: String
    let glyph: Glyph
    let title: String
    /// Drawn after the title in muted ink, for example ◆ for an annotated tag.
    let marker: String?
    let markerTooltip: String?
    let detail: String
    let date: Date
    let sha: String
    /// Extra words the filter matches besides the title.
    let searchText: String
}

/// A button below the list that acts on the selected entry.
struct PanelAction {
    let title: String
    let isDestructive: Bool
    let isEnabled: (String) -> Bool
    let perform: (String) -> Void

    init(_ title: String, isDestructive: Bool = false, isEnabled: @escaping (String) -> Bool = { _ in true }, perform: @escaping (String) -> Void) {
        self.title = title
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.perform = perform
    }
}

/// The content of a sidebar popover: title with counter, a filter once the list is long, the entries, and the actions for the selected one.
/// A click selects an entry, a double click activates it, a right click opens its menu.
final class PanelListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private typealias P = Theme.Panel

    var onSelect: ((String) -> Void)?
    var onActivate: ((String) -> Void)?
    var menuItems: ((String) -> [NSMenuItem])?
    var actions: [PanelAction] = [] { didSet { rebuildFooter() } }

    private(set) var rows: [PanelRow] = []
    private(set) var shownRows: [PanelRow] = []
    private let titleLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    let filterField = NSSearchField()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footer = NSStackView()
    private(set) var footerButtons: [NSButton] = []
    private var tableHeight: NSLayoutConstraint!
    private var filterHeight: NSLayoutConstraint!

    init(title: String, empty: String, filterPlaceholder: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = Theme.bodyStrong
        titleLabel.textColor = Theme.ink
        countLabel.font = Theme.captionDigits
        countLabel.textColor = Theme.inkMuted
        emptyLabel.stringValue = empty
        emptyLabel.font = Theme.body
        emptyLabel.textColor = Theme.inkMuted
        emptyLabel.alignment = .center

        filterField.placeholderString = filterPlaceholder
        filterField.delegate = self
        filterField.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = P.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        footer.orientation = .horizontal
        footer.spacing = Theme.Space.s

        let header = NSStackView(views: [titleLabel, countLabel])
        header.spacing = Theme.Space.s
        for view in [header, filterField, scrollView, emptyLabel, footer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        tableHeight = scrollView.heightAnchor.constraint(equalToConstant: P.rowHeight)
        filterHeight = filterField.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: P.width),
            header.topAnchor.constraint(equalTo: topAnchor, constant: P.padding),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P.padding),
            filterField.topAnchor.constraint(equalTo: header.bottomAnchor, constant: Theme.Space.s),
            filterField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P.padding),
            filterField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P.padding),
            scrollView.topAnchor.constraint(equalTo: filterField.bottomAnchor, constant: Theme.Space.xs),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: P.listInset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P.listInset),
            tableHeight,
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            footer.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Theme.Space.s),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P.padding),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -P.padding),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        Theme.surface2.setFill()
        bounds.fill()
    }

    var selectedID: String? {
        let row = tableView.selectedRow
        return shownRows.indices.contains(row) ? shownRows[row].id : nil
    }

    /// Replaces the entries and keeps the selection on the same entry while it exists.
    func show(_ newRows: [PanelRow]) {
        let selected = selectedID
        rows = newRows
        countLabel.stringValue = "\(rows.count)"
        let filters = rows.count > P.filterThreshold
        filterField.isHidden = !filters
        filterHeight.isActive = !filters
        if !filters { filterField.stringValue = "" }
        applyFilter()
        if let selected, let index = shownRows.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        updateFooter()
    }

    func select(id: String) {
        guard let index = shownRows.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
    }

    /// Characters of the query in order anywhere in the title, like GitHub's ref picker, or the query as a whole in the other words.
    static func matches(_ row: PanelRow, query: String) -> Bool {
        let query = query.lowercased().filter { !$0.isWhitespace }
        guard !query.isEmpty else { return true }
        if row.searchText.lowercased().contains(query) { return true }
        var remaining = Substring(query)
        for character in row.title.lowercased() where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return false
    }

    private func applyFilter() {
        let query = filterField.stringValue
        shownRows = rows.filter { Self.matches($0, query: query) }
        tableView.reloadData()
        emptyLabel.isHidden = !shownRows.isEmpty
        let visible = min(max(shownRows.count, 1), P.maxVisibleRows)
        tableHeight.constant = CGFloat(visible) * P.rowHeight
    }

    func controlTextDidChange(_ notification: Notification) {
        applyFilter()
        if !shownRows.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        updateFooter()
    }

    /// Return in the filter activates the selected entry, the arrow keys move the selection.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if let id = selectedID { onActivate?(id) }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let target = min(max(tableView.selectedRow + step, 0), shownRows.count - 1)
            if target >= 0 { select(id: shownRows[target].id) }
            return true
        default:
            return false
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shownRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: PanelRowView.identifier, owner: nil) as? PanelRowView ?? PanelRowView()
        view.row = shownRows[row]
        view.onPress = { [weak self] clickCount in self?.pressed(row: row, clickCount: clickCount) }
        view.toolTip = shownRows[row].markerTooltip
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PanelSelectionRowView()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFooter()
        if let id = selectedID { onSelect?(id) }
    }

    /// The rows take the press themselves: a popover of an inactive window is never key, and the table would let the first click go by.
    private func pressed(row: Int, clickCount: Int) {
        guard shownRows.indices.contains(row) else { return }
        window?.makeFirstResponder(tableView)
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if clickCount == 2 { onActivate?(shownRows[row].id) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard shownRows.indices.contains(row), let items = menuItems?(shownRows[row].id) else { return }
        items.forEach(menu.addItem)
    }

    // MARK: Footer

    private func rebuildFooter() {
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        footerButtons = actions.enumerated().map { index, action in
            let button = NSButton(title: action.title, target: self, action: #selector(runAction(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.hasDestructiveAction = action.isDestructive
            footer.addArrangedSubview(button)
            return button
        }
        updateFooter()
    }

    private func updateFooter() {
        let selected = selectedID
        for (button, action) in zip(footerButtons, actions) {
            button.isEnabled = selected.map(action.isEnabled) ?? false
        }
    }

    @objc private func runAction(_ sender: NSButton) {
        guard let id = selectedID, actions.indices.contains(sender.tag) else { return }
        actions[sender.tag].perform(id)
    }
}
