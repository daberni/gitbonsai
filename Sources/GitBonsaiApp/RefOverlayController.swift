import AppKit

/// Expands a history row's ref pills when the label column cuts some of them off: after the pointer rests on the row's labels, or at once on a click on its "+n" counter.
/// Only the row under the pointer is laid out at full length, from the model its visible row view already holds.
@MainActor
final class RefOverlayController {
    /// Single click on the expanded labels selects their row, a double click activates it like a double click on the row, with the pill under the pointer.
    var select: ((Int) -> Void)?
    var activate: ((Int, PillRef?) -> Void)?
    var menuItems: ((Int) -> [NSMenuItem])?
    /// Items for the context menu of one pill of a row.
    var pillMenuItems: ((Int, PillRef) -> [NSMenuItem])?

    private let table: HistoryTableView
    let overlay = RefOverlayView()
    private var pending: (row: Int, timer: Timer)?
    private var scrollObserver: NSObjectProtocol?

    var shownRow: Int? { overlay.content?.row }

    init(table: HistoryTableView) {
        self.table = table
        table.onHover = { [weak self] point in self?.hover(at: point) }
        table.onPressLabels = { [weak self] point in self?.pressCounter(at: point) ?? false }
        table.onLayoutChange = { [weak self] in self?.collapse() }
        table.onRowsReloaded = { [weak self] rows in self?.rowsReloaded(rows) }
        overlay.onPress = { [weak self] event in self?.press(event) }
        table.labelMenu = { [weak self] point in self?.labelMenu(at: point) }
        overlay.makeMenu = { [weak self] event in self?.overlayMenu(for: event) }
    }

    // MARK: Pointer

    /// The pointer moved to `point` in the table, or left it (nil).
    func hover(at point: NSPoint?) {
        guard let point else { return collapse() }
        if let card = overlay.content?.card, card.contains(point) { return cancelPending() }
        guard let target = target(at: point), target.compact.hidesSomething else { return collapse() }
        if shownRow == target.row { return }
        // Once one row is expanded the pointer is reading labels, so the next row follows without a delay.
        if shownRow != nil { return open(target.row) }
        if pending?.row == target.row { return }
        cancelPending()
        let row = target.row
        let timer = Timer(timeInterval: Theme.RefOverlay.hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pending = nil
                self?.open(row)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pending = (row, timer)
    }

    /// A press on a row's "+n" counter expands its labels at once. Returns whether it was taken.
    func pressCounter(at point: NSPoint) -> Bool {
        guard let target = target(at: point), RefPills.hit(target.compact, at: point) == .counter else { return false }
        cancelPending()
        open(target.row)
        return true
    }

    /// The pill a row draws at `point` in the table, for a double click on it.
    func pill(at point: NSPoint) -> PillRef? {
        guard let target = target(at: point), case .pill(let index) = RefPills.hit(target.compact, at: point) else { return nil }
        return target.model.pills[index].ref
    }

    // MARK: Menus

    /// A right-click on a pill opens that ref's menu; on the "+n" counter it expands the labels instead. Anywhere else in the row is left to the row's menu (nil).
    private func labelMenu(at point: NSPoint) -> HistoryTableView.LabelMenu? {
        guard let target = target(at: point) else { return nil }
        switch RefPills.hit(target.compact, at: point) {
        case .counter:
            cancelPending()
            open(target.row)
            return HistoryTableView.LabelMenu.none
        case .pill(let index):
            return Self.menu(pillMenuItems?(target.row, target.model.pills[index].ref) ?? []).map(HistoryTableView.LabelMenu.menu)
        case nil:
            return nil
        }
    }

    /// A pill in the expanded labels gets its own menu, the card around them the row's menu.
    private func overlayMenu(for event: NSEvent) -> NSMenu? {
        guard let row = shownRow, let content = overlay.content else { return nil }
        let point = table.convert(event.locationInWindow, from: nil)
        if let placement = RefPills.hit(content.placements, at: point), let menu = Self.menu(pillMenuItems?(row, content.pills[placement.index].ref) ?? []) { return menu }
        return Self.menu(menuItems?(row) ?? [])
    }

    private static func menu(_ items: [NSMenuItem]) -> NSMenu? {
        guard !items.isEmpty else { return nil }
        let menu = NSMenu()
        items.forEach(menu.addItem)
        return menu
    }

    private func press(_ event: NSEvent) {
        guard let row = shownRow else { return }
        table.window?.makeFirstResponder(table)
        guard event.clickCount == 2 else { select?(row); return }
        let point = table.convert(event.locationInWindow, from: nil)
        let pill = overlay.content.flatMap { content in RefPills.hit(content.placements, at: point).map { content.pills[$0.index].ref } }
        activate?(row, pill)
    }

    // MARK: Showing

    private struct Target {
        let row: Int
        let model: GraphRowView.Model
        let compact: RefPills.CompactLayout
        let labelEnd: CGFloat
    }

    /// The row whose label area is under `point`, with its pills as the row draws them.
    private func target(at point: NSPoint) -> Target? {
        let row = table.row(at: point)
        guard row >= 0, let target = target(row: row), let label = target.model.columns.layout(in: table.bounds.width).label, label.contains(point.x) else { return nil }
        return target
    }

    private func target(row: Int) -> Target? {
        guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? GraphRowView, let model = view.model, !model.pills.isEmpty, let label = model.columns.layout(in: table.bounds.width).label else { return nil }
        let compact = RefPills.compactLayout(model.pills, labelEnd: label.upperBound, midY: table.rect(ofRow: row).midY)
        return Target(row: row, model: model, compact: compact, labelEnd: label.upperBound)
    }

    private func open(_ row: Int) {
        guard let target = target(row: row), target.compact.hidesSomething else { return collapse() }
        let anchor = target.labelEnd - Theme.Pill.trailing
        overlay.content = RefOverlayView.layout(target.model.pills, row: row, rowRect: table.rect(ofRow: row), anchorRight: anchor, visible: table.visibleRect, strand: Theme.strand(target.model.row.color), isSelected: target.model.isSelected)
        if overlay.superview !== table || table.subviews.last !== overlay {
            table.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        observeScrolling()
    }

    /// Esc closes the expanded labels first; returns whether there were any.
    func cancel() -> Bool {
        guard shownRow != nil else { return false }
        collapse()
        return true
    }

    func collapse() {
        cancelPending()
        guard overlay.content != nil else { return }
        overlay.content = nil
        overlay.removeFromSuperview()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        scrollObserver = nil
    }

    private func cancelPending() {
        pending?.timer.invalidate()
        pending = nil
    }

    /// The shown row was drawn again, after a selection change or new refs: the expansion follows it.
    private func rowsReloaded(_ rows: IndexSet) {
        guard let row = shownRow, rows.contains(row) else { return }
        open(row)
    }

    /// Scrolling moves the rows away from the pointer, so the expansion closes.
    private func observeScrolling() {
        guard scrollObserver == nil, let clip = table.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
    }
}
