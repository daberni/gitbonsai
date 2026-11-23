import AppKit
import GitEngine

/// Sections of file rows with a caption and an optional action, and the selected files across all of them, in one table that creates views only for the visible rows.
/// A click selects one file, or deselects it when it is the only one; ⌘-click toggles a file, ⇧-click selects the range from the last clicked one.
/// The table has no scroll view of its own: it is as tall as its rows and scrolls with the detail panel, which still limits the views to the visible ones.
final class FileListView: NSView {
    struct Section {
        let title: String
        let rows: [FileRowView.Model]
        /// For instance "Stage all".
        let action: (title: String, perform: () -> Void)?
    }

    /// A table row: a section's header or one of its files.
    fileprivate enum Row {
        case header(Int)
        case file(Int)
    }

    /// The selection changed by a click or a key; empty when the last file was deselected.
    var onSelect: (([FileSelection]) -> Void)?
    var onAction: (([FileSelection], FileRowView.Action) -> Void)?
    /// The context menu's entries for the files it acts on; none leaves the row without a menu.
    var menuItems: (([FileRowView.Model]) -> [NSMenuItem])?
    /// In row order.
    var selection: [FileSelection] = [] { didSet { applySelection() } }
    /// Where ⇧-click and ⇧-arrow ranges start, and where the arrow keys move from.
    private var anchor: FileSelection?
    private var cursor: FileSelection?
    /// While the rows belong to an earlier selection they take no clicks or keys; once loading takes long they are hidden and keep their room.
    enum Freshness { case current, stale, loading }
    var freshness = Freshness.current {
        didSet { table.isHidden = freshness == .loading }
    }
    /// The rows shown, in order.
    private(set) var models: [FileRowView.Model] = []
    private var sections: [Section] = []
    private var rows: [Row] = []
    /// The table row of every file, by its position in `models`.
    private var tableRows: [Int] = []
    private var rowOfFile: [FileSelection: Int] = [:]
    private let table = FileTable()
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightConstraint.isActive = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = []
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.gridStyleMask = []
        table.list = self
        table.dataSource = self
        table.delegate = self
        addSubview(table)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        table.tableColumns.first?.width = bounds.width
        table.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        freshness == .current ? super.hitTest(point) : nil
    }

    func show(_ sections: [Section]) {
        freshness = .current
        self.sections = sections
        rows = []
        models = []
        tableRows = []
        for (index, section) in sections.enumerated() {
            rows.append(.header(index))
            for model in section.rows {
                tableRows.append(rows.count)
                rows.append(.file(models.count))
                models.append(model)
            }
        }
        rowOfFile = Dictionary(models.enumerated().map { ($1.selection, $0) }, uniquingKeysWith: { first, _ in first })
        let headerHeights = sections.indices.reduce(0) { $0 + headerHeight($1) }
        heightConstraint.constant = headerHeights + CGFloat(models.count) * Theme.FileList.rowHeight
        table.reloadData()
        applySelection()
    }

    private func headerHeight(_ section: Int) -> CGFloat {
        Theme.FileList.sectionHeight + (section > 0 ? Theme.FileList.sectionGap : 0)
    }

    // MARK: Selection

    /// The table's own selection mirrors `selection`; the rows draw it themselves.
    private func applySelection() {
        let indexes = IndexSet(selection.compactMap { rowOfFile[$0].map { tableRows[$0] } })
        if table.selectedRowIndexes != indexes { table.selectRowIndexes(indexes, byExtendingSelection: false) }
        table.enumerateAvailableRowViews { rowView, row in
            (rowView.view(atColumn: 0) as? FileRowView)?.isSelected = indexes.contains(row)
        }
    }

    private func select(_ files: [FileSelection]) {
        selection = files
        onSelect?(files)
    }

    private func index(of file: FileSelection?) -> Int? {
        file.flatMap { rowOfFile[$0] }
    }

    private func range(_ start: Int, _ end: Int) -> [FileSelection] {
        models[min(start, end)...max(start, end)].map(\.selection)
    }

    fileprivate func file(atTableRow row: Int) -> Int? {
        guard rows.indices.contains(row), case let .file(index) = rows[row] else { return nil }
        return index
    }

    // MARK: Keyboard

    /// ↑ and ↓ walk through the rows of all sections as one list; a click on a row gives the list the focus.
    fileprivate var takesFocus: Bool { !models.isEmpty && freshness == .current }

    /// An arrow moves a single selection on from the last clicked file; with ⇧ it grows or shrinks the range from the anchor instead.
    func moveSelection(by offset: Int, extending: Bool = false) {
        guard !models.isEmpty, freshness == .current else { return }
        let current = index(of: cursor) ?? models.lastIndex { selection.contains($0.selection) }
        let target = current.map { min(max($0 + offset, 0), models.count - 1) } ?? (offset > 0 ? 0 : models.count - 1)
        guard target != current else { return }
        let file = models[target].selection
        if extending, let start = index(of: anchor) {
            cursor = file
            select(range(start, target))
        } else {
            anchor = file
            cursor = file
            select([file])
        }
        table.scrollRowToVisible(tableRows[target])
    }

    /// Type-select chose a file.
    fileprivate func typeSelected(_ index: Int) {
        let file = models[index].selection
        anchor = file
        cursor = file
        select([file])
    }

    // MARK: Mouse

    fileprivate func click(_ position: Int, flags: NSEvent.ModifierFlags) {
        let file = models[position].selection
        if flags.contains(.command) {
            anchor = file
            cursor = file
            select(selection.contains(file) ? selection.filter { $0 != file } : models.map(\.selection).filter { selection.contains($0) || $0 == file })
        } else if flags.contains(.shift), let start = index(of: anchor) {
            cursor = file
            select(range(start, position))
        } else if selection == [file] {
            anchor = nil
            cursor = nil
            select([])
        } else {
            anchor = file
            cursor = file
            select([file])
        }
        table.scrollRowToVisible(tableRows[position])
    }

    fileprivate func perform(_ action: FileRowView.Action, on index: Int) {
        onAction?(targets(of: models[index], fitting: action).map(\.selection), action)
    }

    fileprivate func menu(for index: Int) -> NSMenu? {
        guard let items = menuItems?(targets(of: models[index])), !items.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    /// A row that is part of a larger selection speaks for all selected rows; any other row only for itself, as in Finder.
    private func targets(of model: FileRowView.Model) -> [FileRowView.Model] {
        guard selection.contains(model.selection) else { return [model] }
        return models.filter { selection.contains($0.selection) }
    }

    /// A hovered button acts on every selected file only when each of them offers it.
    private func targets(of model: FileRowView.Model, fitting action: FileRowView.Action) -> [FileRowView.Model] {
        let all = targets(of: model)
        return all.allSatisfy { $0.actions.contains(action) } ? all : [model]
    }

    @objc fileprivate func runAction(_ sender: NSButton) {
        guard sections.indices.contains(sender.tag) else { return }
        sections[sender.tag].action?.perform()
    }
}

extension FileListView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case let .header(section): headerHeight(section)
        case .file: Theme.FileList.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case let .header(section):
            let header = tableView.makeView(withIdentifier: FileSectionHeaderView.identifier, owner: nil) as? FileSectionHeaderView ?? FileSectionHeaderView()
            header.show(sections[section], tag: section, target: self, action: #selector(runAction(_:)))
            return header
        case let .file(index):
            let model = models[index]
            let cell: FileRowView
            if let reused = tableView.makeView(withIdentifier: FileRowView.identifier, owner: nil) as? FileRowView {
                cell = reused
                cell.model = model
            } else {
                cell = FileRowView(model: model)
                cell.identifier = FileRowView.identifier
            }
            cell.isSelected = selection.contains(model.selection)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { file(atTableRow: row) != nil }

    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposed: IndexSet) -> IndexSet {
        proposed.filteredIndexSet { file(atTableRow: $0) != nil }
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        file(atTableRow: row).map { models[$0].selection.name }
    }

    /// Type-select changes the table's selection directly; it becomes the list's selection like a click.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let chosen = table.selectedRowIndexes.compactMap(file(atTableRow:))
        guard chosen.map({ models[$0].selection }) != selection else { return }
        if chosen.count == 1 { typeSelected(chosen[0]) } else { applySelection() }
    }
}

extension FileRowView {
    static let identifier = NSUserInterfaceItemIdentifier("fileRow")
}

/// The table under `FileListView`: clicks, arrows and menus go to the list's own rules, everything else (type-select, focus) is the table's.
private final class FileTable: NSTableView {
    weak var list: FileListView?

    override var acceptsFirstResponder: Bool { list?.takesFocus ?? false }

    /// Like a Finder list, a click into an inactive window already chooses the file.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click on a file acts on release, on a hovered action button or by the list's selection rules; headers keep the table's handling for their links.
    override func mouseDown(with event: NSEvent) {
        guard let list else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard let index = list.file(atTableRow: row) else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        // The selection changes on release, so a press that leaves the row does nothing, as before.
        var up: NSEvent?
        while up == nil, let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseUp { up = next }
        }
        guard let up, self.row(at: convert(up.locationInWindow, from: nil)) == row else { return }
        if let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? FileRowView, let action = cell.action(at: cell.convert(up.locationInWindow, from: nil)) {
            list.perform(action, on: index)
        } else {
            list.click(index, flags: event.modifierFlags)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard let list, let index = list.file(atTableRow: row) else { return nil }
        return list.menu(for: index)
    }

    override func keyDown(with event: NSEvent) {
        let extending = event.modifierFlags.contains(.shift)
        switch event.specialKey {
        case .upArrow?: list?.moveSelection(by: -1, extending: extending)
        case .downArrow?: list?.moveSelection(by: 1, extending: extending)
        default: super.keyDown(with: event)
        }
    }
}

/// A section's caption in capitals with its optional action link on the right, at the bottom of its row; the room above it is the gap to the previous section.
private final class FileSectionHeaderView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("fileSection")
    private let title = NSTextField(labelWithString: "")
    private let button = LinkButton(target: nil, action: #selector(FileListView.runAction(_:)))

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        for view in [title, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Space.xs),
            title.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.FileList.sectionHeight / 2),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.xs),
            button.centerYAnchor.constraint(equalTo: title.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ section: FileListView.Section, tag: Int, target: AnyObject, action: Selector) {
        title.attributedStringValue = NSAttributedString(string: section.title.uppercased(with: AppLanguage.locale), attributes: [.font: Theme.label, .foregroundColor: Theme.inkMuted, .kern: Theme.labelKern])
        button.isHidden = section.action == nil
        if let link = section.action {
            button.attributedTitle = NSAttributedString(string: link.title, attributes: [.font: Theme.caption, .foregroundColor: Theme.moss])
            button.tag = tag
            button.target = target
            button.action = action
        }
    }
}
