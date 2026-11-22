import AppKit

/// The content of a sidebar popover: title with counter, a filter once the list is long, the entries, and the actions for the selected one.
/// A click selects an entry, a double click activates it, a right click opens its menu.
final class PanelListView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    private typealias P = Theme.Panel

    var onSelect: ((String) -> Void)?
    var onActivate: ((String) -> Void)?
    var menuItems: ((String) -> [NSMenuItem])?
    var actions: [PanelAction] = [] { didSet { rebuildFooter() } }
    /// Offered in the filter's menu; with scopes the filter is always shown.
    var scopes: [PanelScope] = [] {
        didSet {
            if activeScope.map({ !scopes.indices.contains($0) }) ?? false { activeScope = nil }
            rebuildScopeMenu()
        }
    }
    var activeScope: Int?
    /// A quiet line next to the counter, for example why something could not be shown.
    var note: String? {
        didSet {
            noteLabel.stringValue = note ?? ""
            noteLabel.isHidden = note == nil
        }
    }
    /// A quiet spinner at the header's end while the entries are being brought up to date; the entries stay as they are meanwhile.
    /// Its slot is always there, so nothing moves when it starts or stops.
    var isBusy = false {
        didSet {
            guard isBusy != oldValue else { return }
            if isBusy { busyIndicator.startAnimation(nil) } else { busyIndicator.stopAnimation(nil) }
        }
    }

    private(set) var rows: [PanelRow] = []
    private(set) var shownRows: [PanelRow] = []
    private let titleLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    let busyIndicator = NSProgressIndicator()
    let filterPlaceholder: String
    private let empty: String
    private let noMatch: String
    let filterField = NSSearchField()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: "")
    let footer = NSStackView()
    var footerButtons: [NSButton] = []
    private var tableHeight: NSLayoutConstraint!
    private var filterHeight: NSLayoutConstraint!

    /// `empty` is shown without entries, `noMatch` when the filter text matches none.
    init(title: LocalizedStringResource, empty: LocalizedStringResource, noMatch: LocalizedStringResource, filterPlaceholder: LocalizedStringResource) {
        self.filterPlaceholder = filterPlaceholder.text
        self.empty = empty.text
        self.noMatch = noMatch.text
        super.init(frame: .zero)
        titleLabel.stringValue = title.text
        titleLabel.font = Theme.bodyStrong
        titleLabel.textColor = Theme.ink
        countLabel.font = Theme.captionDigits
        countLabel.textColor = Theme.inkMuted
        noteLabel.font = Theme.caption
        noteLabel.textColor = Theme.inkFaint
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.isHidden = true
        busyIndicator.style = .spinning
        busyIndicator.controlSize = .mini
        busyIndicator.isDisplayedWhenStopped = false
        emptyLabel.stringValue = empty.text
        emptyLabel.textColor = Theme.inkMuted
        emptyLabel.font = Theme.body
        emptyLabel.alignment = .center

        filterField.placeholderString = filterPlaceholder.text
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

        // Title and counter lead, the note and the busy slot trail: a changing count or note never moves anything else in the header.
        let header = NSStackView()
        header.spacing = Theme.Space.s
        header.alignment = .centerY
        header.addView(titleLabel, in: .leading)
        header.addView(countLabel, in: .leading)
        header.addView(noteLabel, in: .trailing)
        header.addView(busyIndicator, in: .trailing)
        noteLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -P.padding),
            header.heightAnchor.constraint(equalToConstant: P.headerHeight),
            busyIndicator.widthAnchor.constraint(equalToConstant: P.busySlot),
            busyIndicator.heightAnchor.constraint(equalToConstant: P.busySlot),
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

    /// Replaces the entries in place: the filter text, the scroll position and the selection, while its entry exists, stay.
    func show(_ newRows: [PanelRow]) {
        let selected = selectedID
        let scrollOrigin = scrollView.contentView.bounds.origin
        rows = newRows
        // The list keeps the height of all entries while filtering, so the popover does not jump and its content never outgrows it.
        tableHeight.constant = CGFloat(min(max(rows.count, 1), P.maxVisibleRows)) * P.rowHeight
        let filters = rows.count > P.filterThreshold || !scopes.isEmpty || !filterField.stringValue.isEmpty
        filterField.isHidden = !filters
        filterHeight.isActive = !filters
        if !filters {
            filterField.stringValue = ""
            activeScope = nil
        }
        applyFilter()
        if let selected, let index = shownRows.firstIndex(where: { $0.id == selected }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            // The table keeps the selected index across a reload, which would now point at a neighbour.
            tableView.deselectAll(nil)
        }
        layoutSubtreeIfNeeded()
        tableView.scroll(scrollOrigin)
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

    func applyFilter() {
        let query = filterField.stringValue
        let scope = activeScope.map { scopes[$0] }
        shownRows = rows.filter { row in Self.matches(row, query: query) && (scope?.includes(row.id) ?? true) }
        tableView.reloadData()
        emptyLabel.isHidden = !shownRows.isEmpty
        let filtered = !query.isEmpty || scope != nil
        emptyLabel.stringValue = rows.isEmpty ? empty : !query.isEmpty ? noMatch : scope?.empty ?? empty
        countLabel.stringValue = filtered ? "\(shownRows.count)/\(rows.count)" : "\(rows.count)"
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
        view.toolTip = shownRows[row].tooltip
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
}
