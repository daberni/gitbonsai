import AppKit
import GitEngine
import GraphLayout

/// Takes in the view model's row changes and keeps the selected commit across them.
extension HistoryViewController {
    // MARK: Changes from the view model

    func rowsAppended(_ range: Range<Int>) {
        tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
        if range.lowerBound > 0 { tableView.reloadData(forRowIndexes: IndexSet(integer: range.lowerBound - 1), columnIndexes: IndexSet(integer: 0)) }
        columnsController.update(laneCount: viewModel.maxLaneCount)
        search.commitsAppended()
    }

    /// A reload that a later refresh restarted keeps the anchor of the first one, since nothing was selected in between.
    func rowsReset(focus: GraphViewModel.Focus) {
        headAfterReload = focus == .head
        currentAfterReload = focus == .current || focus == .followHead
        if focus != .keepSelection {
            focusAfterReload = nil
        } else if let anchor = anchor() {
            focusAfterReload = anchor
        }
        selectedRow = -1
        selectedRows = []
        selectedID = nil
        otherSelectedIDs = []
        tableView.reloadData()
        search.historyChanged()
        onSelect?([])
    }

    func rowsShifted() {
        tableView.reloadData()
        columnsController.update(laneCount: viewModel.maxLaneCount)
        search.historyChanged()
    }

    /// A refresh swapped in new rows. The table takes in only the difference without animation, so unchanged rows stay as they are on screen; a reorder reloads every row once.
    /// The selected commit stays where it was on screen unless the focus moves elsewhere or the commit left the history.
    func rowsRebuilt(_ diff: HistoryRowDiff?, focus: GraphViewModel.Focus) {
        let kept = focus == .keepSelection ? anchor() : nil
        selectedRow = -1
        selectedRows = []
        selectedID = nil
        otherSelectedIDs = []
        isApplyingRows = true
        if let diff {
            tableView.beginUpdates()
            tableView.removeRows(at: diff.removed, withAnimation: [])
            tableView.insertRows(at: diff.inserted, withAnimation: [])
            tableView.endUpdates()
            tableView.reloadData(forRowIndexes: diff.changed, columnIndexes: IndexSet(integer: 0))
        } else {
            tableView.reloadData()
        }
        isApplyingRows = false
        columnsController.update(laneCount: viewModel.maxLaneCount)
        search.historyChanged()
        switch focus {
        case .keepSelection where restore(kept): break
        case .head where selectHead(): break
        default: selectCurrentRow(scrollToHead: true)
        }
        // Selecting the rows the table already moved the selection to sends no notification.
        if tableView.selectedRowIndexes != selectedRows { adoptTableSelection() }
    }

    func metadataChanged() {
        search.refsMayHaveChanged()
        reloadVisibleRows()
        guard selectedRow < 0, !viewModel.isLoading else { return }
        let anchor = focusAfterReload
        focusAfterReload = nil
        if headAfterReload {
            headAfterReload = false
            if selectHead() { return }
        }
        let follow = currentAfterReload
        currentAfterReload = false
        if !restore(anchor) { selectCurrentRow(scrollToHead: anchor != nil || follow) }
    }

    // MARK: Keeping the selection

    /// Keeps `old` selected as `new` across the next rebuild or reload, for a rewrite that replaced it.
    func followRewrite(of old: String, to new: String) {
        rewrittenCommits[old] = new
    }

    private func anchor() -> Anchor? {
        guard let selectedID, selectedRow >= 0 else { return nil }
        let top = tableView.visibleRect.minY
        return Anchor(id: selectedID, others: otherSelectedIDs, offset: tableView.rect(ofRow: selectedRow).minY - top, pinnedToTop: top <= Theme.Graph.rowHeight / 2)
    }

    /// Selects the anchored commits again and scrolls so that the anchor's row sits where it sat before, or keeps the top in view when the history was at its top. False when that commit is no longer in the history; others that left stay unselected.
    private func restore(_ anchor: Anchor?) -> Bool {
        let rewritten = rewrittenCommits
        rewrittenCommits = [:]
        guard let anchor, let row = viewModel.rowIndex(of: rewritten[anchor.id] ?? anchor.id) else { return false }
        let others = IndexSet(anchor.others.compactMap { viewModel.rowIndex(of: rewritten[$0] ?? $0) })
        // One change for all rows: a passing selection of fewer rows would count as navigation.
        tableView.selectRowIndexes(others.union(IndexSet(integer: row)), byExtendingSelection: false)
        guard let clip = tableView.enclosingScrollView?.contentView else { return true }
        let maxY = max(tableView.bounds.height - clip.bounds.height, 0)
        let y = anchor.pinnedToTop ? 0 : min(max(tableView.rect(ofRow: row).minY - anchor.offset, 0), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        tableView.enclosingScrollView?.reflectScrolledClipView(clip)
        return true
    }

    func reloadVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: IndexSet(integer: 0))
    }
}
