import AppKit

/// What a ⌘- or ⇧-click makes of the history selection. ⌘ adds a row or takes it out, ⇧ selects every row from the anchor to it.
/// The working directory is no commit to compare and stays out of a selection of several; the last selected row cannot be taken out.
struct HistoryMultiSelection {
    /// Where a ⇧-click range starts: the row clicked last without ⇧.
    var anchor: Int?

    /// The new selection, or nil when the click leaves it as it is.
    mutating func rows(afterClickOn row: Int, flags: NSEvent.ModifierFlags, selected: IndexSet, lastSelected: Int, wipRow: Int?) -> IndexSet? {
        var rows = selected
        let start = anchor ?? lastSelected
        if flags.contains(.shift), start >= 0 {
            rows = IndexSet(integersIn: min(start, row)...max(start, row))
        } else if rows.contains(row) {
            guard rows.count > 1 else { return nil }
            rows.remove(row)
        } else {
            rows.insert(row)
        }
        if rows.count > 1, let wipRow { rows.remove(wipRow) }
        guard !rows.isEmpty else { return nil }
        if flags.contains(.shift) { anchor = start } else if rows.contains(row) { anchor = row }
        return rows
    }
}
