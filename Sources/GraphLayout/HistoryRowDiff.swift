import Foundation

/// How the history table gets from the rows it shows to the rows of a refresh, matched by commit ID, so that it changes only what changed.
public struct HistoryRowDiff: Equatable, Sendable {
    /// Rows that leave, as indices into the old rows.
    public var removed: IndexSet
    /// Rows that arrive, as indices into the new rows.
    public var inserted: IndexSet
    /// Rows that stay but draw differently, because their own graph row or a neighbour's changed; a row draws the strands it shares with the rows above and below. Indices into the new rows.
    public var changed: IndexSet

    public init(removed: IndexSet = [], inserted: IndexSet = [], changed: IndexSet = []) {
        self.removed = removed
        self.inserted = inserted
        self.changed = changed
    }

    /// Nil when rows that stay changed their order: then removals and insertions cannot express it and the whole table has to be reloaded. Linear in the number of rows.
    public static func between(_ old: [GraphRow], _ new: [GraphRow]) -> HistoryRowDiff? {
        var newIndexByID: [String: Int] = [:]
        newIndexByID.reserveCapacity(new.count)
        for (index, row) in new.enumerated() { newIndexByID[row.commitID] = index }
        var removed = IndexSet()
        var oldIndexOfNew = [Int](repeating: -1, count: new.count)
        var lastKept = -1
        for (oldIndex, row) in old.enumerated() {
            guard let newIndex = newIndexByID[row.commitID] else {
                removed.insert(oldIndex)
                continue
            }
            if newIndex < lastKept { return nil }
            lastKept = newIndex
            oldIndexOfNew[newIndex] = oldIndex
        }
        var inserted = IndexSet()
        var changed = IndexSet()
        for (newIndex, oldIndex) in oldIndexOfNew.enumerated() {
            guard oldIndex >= 0 else {
                inserted.insert(newIndex)
                continue
            }
            let ownChanged = old[oldIndex] != new[newIndex]
            let aboveChanged = row(in: old, at: oldIndex - 1) != row(in: new, at: newIndex - 1)
            let belowChanged = row(in: old, at: oldIndex + 1) != row(in: new, at: newIndex + 1)
            if ownChanged || aboveChanged || belowChanged { changed.insert(newIndex) }
        }
        return HistoryRowDiff(removed: removed, inserted: inserted, changed: changed)
    }

    private static func row(in rows: [GraphRow], at index: Int) -> GraphRow? {
        rows.indices.contains(index) ? rows[index] : nil
    }
}
