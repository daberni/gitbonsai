import AppKit
import GitEngine

/// The steps of the interactive rebase sheet, newest on top like the history and the preview; the plan keeps git's todo order, `RebasePlan.step(atRow:)` maps between them.
/// Drag a row a row or press ⌥↑/⌥↓ to move it, choose its action in the pop-up or with p, r, e, s, f, d.
/// Its columns work like the history's: boundaries drag over the header or the rows with a guide line, widths are remembered, and wider columns scroll sideways.
@MainActor
final class RebaseStepList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = RebaseStepTable()
    let scrollView = NSScrollView()
    let header = RebaseColumnHeaderView()
    private let guide = ColumnGuideView()
    private(set) var columns: RebaseColumns
    private let store: ColumnStore
    private let model: InteractiveRebaseModel
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("step"))
    var onSelect: ((Int?) -> Void)?

    init(model: InteractiveRebaseModel, store: ColumnStore) {
        self.store = store
        columns = RebaseColumns.load(from: store)
        self.model = model
        super.init()
        table.addTableColumn(column)
        header.frame.size.height = Theme.InteractiveRebase.headerHeight
        table.headerView = header
        table.rowHeight = Theme.InteractiveRebase.rowHeight
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = Theme.surface2
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(String(localized: "rebase.steps.accessibility", defaultValue: "Commits of the rebase, newest first", bundle: .module))
        table.onMove = { [weak self] from, to in self?.move(from: from, to: to) }
        table.onShift = { [weak self] offset in self?.shiftSelection(by: offset) }
        table.onAction = { [weak self] action in
            guard let self, let index = selectedIndex else { return }
            model.setAction(action, at: index)
        }
        table.dividers = { [weak self] in self.map { $0.columns.dividers(in: $0.visibleWidth) } ?? [] }
        table.onDrag = { [weak self] column, x in self?.resize(column, to: x) }
        header.onDrag = { [weak self] column, x in self?.resize(column, to: x) }
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.surface2
        // The guide lies over the visible rows and does not scroll; its boundaries are shifted by the sideways scroll.
        guide.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(guide)
        NSLayoutConstraint.activate([
            guide.topAnchor.constraint(equalTo: scrollView.topAnchor),
            guide.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            guide.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            guide.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
        ])
        guide.positions = { [weak self] _ in
            guard let self else { return [] }
            let offset = scrollView.contentView.bounds.minX
            return columns.dividers(in: visibleWidth).map { $0.1 - offset }
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipChanged), name: NSView.frameDidChangeNotification, object: scrollView.contentView)
    }

    /// The width the rows fill when the columns need no more.
    private var visibleWidth: CGFloat { scrollView.contentView.bounds.width }

    private func index(ofRow row: Int) -> Int { model.plan.step(atRow: row) }

    /// The step of the selected row, in the plan's order.
    var selectedIndex: Int? { table.selectedRow >= 0 ? index(ofRow: table.selectedRow) : nil }

    /// Selects the step at `index` of the plan.
    func select(_ index: Int) {
        guard model.steps.indices.contains(index) else { return }
        let row = self.index(ofRow: index)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    /// Selects the top row, the newest step.
    func selectNewest() { select(model.steps.count - 1) }

    /// Shows the model again without rebuilding the rows, so a subject being typed keeps its editor.
    func refresh() {
        for row in model.steps.indices {
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? RebaseStepRowView)?.configure(with: model, at: index(ofRow: row))
        }
    }

    private func resize(_ column: RebaseColumns.Column, to x: CGFloat) {
        var updated = columns
        updated.drag(column, to: x, in: visibleWidth)
        guard updated != columns else { return }
        columns = updated
        applyColumns()
        columns.save(to: store)
    }

    @objc private func clipChanged() {
        applyColumns()
        guide.refresh()
    }

    /// Fits the one table column to the rows' width and moves every visible row's cells onto the columns.
    func applyColumns() {
        let width = columns.totalWidth(in: visibleWidth)
        if column.width != width { column.width = width }
        header.columns = columns
        header.visibleWidth = visibleWidth
        let layout = columns.layout(in: visibleWidth)
        for index in 0..<table.numberOfRows {
            (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? RebaseStepRowView)?.apply(layout)
        }
        guide.refresh()
        table.window?.invalidateCursorRects(for: table)
    }

    private func move(from row: Int, to gap: Int) {
        let landed = model.moveListed(row: row, toGap: gap)
        table.selectRowIndexes(IndexSet(integer: landed), byExtendingSelection: false)
        table.scrollRowToVisible(landed)
    }

    private func shiftSelection(by offset: Int) {
        guard table.selectedRow >= 0 else { return }
        let row = table.selectedRow
        let gap = offset < 0 ? row + offset : row + offset + 1
        guard gap >= 0, gap <= model.steps.count else { return }
        move(from: row, to: gap)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.steps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("step-row")
        let view = tableView.makeView(withIdentifier: identifier, owner: nil) as? RebaseStepRowView ?? RebaseStepRowView(identifier: identifier)
        view.onAction = { [weak self, weak view] action in
            guard let self, let view else { return }
            let row = table.row(for: view)
            if row >= 0 { model.setAction(action, at: index(ofRow: row)) }
        }
        view.onSubject = { [weak self, weak view] subject in
            guard let self, let view else { return }
            let row = table.row(for: view)
            if row >= 0 { model.setSubject(subject, at: index(ofRow: row)) }
        }
        view.apply(columns.layout(in: visibleWidth))
        view.configure(with: model, at: index(ofRow: row))
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        onSelect?(selectedIndex)
    }
}

/// The table of the step list. A press on a row that is not on one of its controls selects it, and dragging from there moves it; the row lands where the line shows.
/// The drag follows the mouse in a tracking loop, so it works for queued events too, the way the harness sends them.
final class RebaseStepTable: NSTableView {
    var dividers: () -> [(RebaseColumns.Column, CGFloat)] = { [] }
    var onDrag: ((RebaseColumns.Column, CGFloat) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onShift: ((Int) -> Void)?
    var onAction: ((RebaseAction) -> Void)?
    private let insertionLine = FillView(color: Theme.moss)

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        ColumnDividers.addCursorRects(to: self, at: dividers().map(\.1))
    }

    override func mouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        if let divider = ColumnDividers.hit(start.x, in: dividers()) {
            ColumnDividers.followDrag(in: self) { onDrag?(divider, $0) }
            return
        }
        let row = row(at: start)
        guard row >= 0, let window else { return super.mouseDown(with: event) }
        window.makeFirstResponder(self)
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        var destination: Int?
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = convert(next.locationInWindow, from: nil)
            guard destination != nil || hypot(point.x - start.x, point.y - start.y) > Theme.dragThreshold else { continue }
            autoscroll(with: next)
            destination = insertionIndex(at: point)
            showInsertionLine(at: destination ?? row)
        }
        insertionLine.removeFromSuperview()
        if let destination, destination != row, destination != row + 1 { onMove?(row, destination) }
    }

    /// The gap between rows nearest to `point`: 0 above the first row, `numberOfRows` below the last.
    private func insertionIndex(at point: NSPoint) -> Int {
        let height = rowHeight + intercellSpacing.height
        return min(max(Int((point.y / height).rounded()), 0), numberOfRows)
    }

    private func showInsertionLine(at index: Int) {
        let height = rowHeight + intercellSpacing.height
        let thickness = Theme.Stroke.strand
        insertionLine.frame = NSRect(x: visibleRect.minX + Theme.Space.s, y: CGFloat(index) * height - thickness / 2, width: visibleRect.width - 2 * Theme.Space.s, height: thickness)
        if insertionLine.superview == nil { addSubview(insertionLine) }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.option), let key = event.specialKey, key == .upArrow || key == .downArrow {
            onShift?(key == .upArrow ? -1 : 1)
            return
        }
        let letters: [String: RebaseAction] = ["p": .pick, "r": .reword, "e": .edit, "s": .squash, "f": .fixup, "d": .drop]
        if modifiers.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty, let action = event.charactersIgnoringModifiers.flatMap({ letters[$0.lowercased()] }) {
            onAction?(action)
            return
        }
        super.keyDown(with: event)
    }
}
