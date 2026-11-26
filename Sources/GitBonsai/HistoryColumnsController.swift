import AppKit
import GitEngine

/// Owns the column layout of the history: widths, visibility, the automatic graph width and the sideways graph scroll.
/// It keeps the header, the table and the hover guide in step and remembers the user's choice.
@MainActor
final class HistoryColumnsController: NSObject {
    private(set) var columns: HistoryColumns
    /// Called after every change, so the visible rows can be redrawn.
    var onChange: (() -> Void)?

    /// Nil while the graph column follows the number of lanes; set once the user has dragged it.
    private var chosenGraphWidth: CGFloat?
    private let store: ColumnStore
    private let settings: AppSettings
    private var laneCount = 1
    private let header: HistoryHeaderView
    private let table: HistoryTableView
    private let guide: ColumnGuideView

    init(header: HistoryHeaderView, table: HistoryTableView, guide: ColumnGuideView, store: ColumnStore, settings: AppSettings) {
        self.store = store
        self.settings = settings
        columns = store.load()
        chosenGraphWidth = store.loadGraphWidth()
        self.header = header
        self.table = table
        self.guide = guide
        super.init()
        header.onDrag = { [weak self] column, x in self?.resize(column, to: x) }
        header.onResetGraph = { [weak self] in self?.resetGraphWidth() }
        header.makeMenu = { [weak self] in self?.menu() ?? NSMenu() }
        table.onDrag = { [weak self] column, x in self?.resize(column, to: x) }
        table.onResetGraph = { [weak self] in self?.resetGraphWidth() }
        table.onGraphScroll = { [weak self] deltaX, point in self?.scrollGraph(by: deltaX, at: point) ?? false }
        guide.positions = { [weak self] width in self?.columns.layout(in: width).dividers.map(\.1) ?? [] }
        push(columns)
    }

    /// Width the graph needs to show every lane.
    private var graphContentWidth: CGFloat {
        Theme.Graph.firstLane + CGFloat(laneCount) * Theme.Graph.lane
    }

    /// Fits the graph column to the lanes unless the user chose a width, and keeps the scroll position inside the graph.
    func update(laneCount: Int) {
        self.laneCount = laneCount
        var updated = columns
        let automatic = Theme.Graph.firstLane + CGFloat(min(laneCount, Theme.Graph.maxVisibleLanes)) * Theme.Graph.lane
        updated.graph = chosenGraphWidth ?? automatic
        updated.graphScrollX = min(max(updated.graphScrollX, 0), max(graphContentWidth - updated.graph, 0))
        updated.graphContentWidth = graphContentWidth
        header.graphContentWidth = graphContentWidth
        apply(updated)
    }

    /// A column boundary was dragged to `x`, in the history's coordinates.
    func resize(_ column: HistoryColumns.Column, to x: CGFloat) {
        var updated = columns
        updated.drag(column, to: x, in: header.bounds.width)
        if column == .graph {
            chosenGraphWidth = updated.graph
            updated.graphScrollX = min(updated.graphScrollX, max(graphContentWidth - updated.graph, 0))
        }
        apply(updated)
        save()
    }

    /// Returns false when the point is outside the graph column, so the scroll goes to the table instead.
    func scrollGraph(by deltaX: CGFloat, at point: NSPoint) -> Bool {
        guard let graph = columns.layout(in: table.bounds.width).graph, graph.contains(point.x) else { return false }
        var updated = columns
        updated.graphScrollX = min(max(columns.graphScrollX - deltaX, 0), max(graphContentWidth - columns.graph, 0))
        apply(updated)
        return true
    }

    private func resetGraphWidth() {
        chosenGraphWidth = nil
        update(laneCount: laneCount)
        save()
    }

    private func apply(_ updated: HistoryColumns) {
        guard updated != columns else { return }
        columns = updated
        push(updated)
        onChange?()
    }

    private func push(_ columns: HistoryColumns) {
        header.columns = columns
        table.columns = columns
        guide.refresh()
    }

    private func save() {
        store.save(columns, graphWidth: chosenGraphWidth)
    }

    // MARK: Menu

    private func menu() -> NSMenu {
        let menu = NSMenu()
        for column in HistoryColumns.Column.allCases {
            let item = NSMenuItem(title: column.title, action: column == .commit ? nil : #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = columns.shows(column) ? .on : .off
            if column == .commit { item.toolTip = String(localized: "history.columns.alwaysShown", defaultValue: "Always shown", bundle: .module, comment: "Why the Commit column cannot be hidden.") }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let automatic = NSMenuItem(title: String(localized: "history.columns.automaticGraphWidth", defaultValue: "Automatic graph width", bundle: .module), action: #selector(toggleAutomaticGraphWidth(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = chosenGraphWidth == nil ? .on : .off
        menu.addItem(automatic)
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: String(localized: "history.columns.order", defaultValue: "Order", bundle: .module, comment: "Column menu header above the history orders.")))
        for order in HistoryOrder.allCases {
            let item = NSMenuItem(title: String(localized: order.title), action: #selector(chooseOrder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            item.state = settings.historyOrder == order ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: String(localized: "history.columns.reset", defaultValue: "Reset columns", bundle: .module), action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = HistoryColumns.Column(rawValue: raw) else { return }
        var updated = columns
        if updated.hidden.remove(column) == nil { updated.hidden.insert(column) }
        apply(updated)
        save()
    }

    @objc private func chooseOrder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let order = HistoryOrder(rawValue: raw) else { return }
        settings.historyOrder = order
    }

    @objc private func toggleAutomaticGraphWidth(_ sender: Any?) {
        chosenGraphWidth = chosenGraphWidth == nil ? columns.graph : nil
        update(laneCount: laneCount)
        save()
    }

    @objc private func resetColumns(_ sender: Any?) {
        chosenGraphWidth = nil
        var updated = HistoryColumns.standard
        updated.graphScrollX = columns.graphScrollX
        apply(updated)
        update(laneCount: laneCount)
        save()
    }
}
