import GitEngine

/// The row for uncommitted changes on top of the laid-out rows.
///
/// A layout pinned to HEAD keeps the leftmost lane for HEAD's strand, so the row sits in HEAD's lane and a strand runs straight down to HEAD through the rows in between.
public struct WorkingDirectoryRow: Sendable {
    /// The lane of the strand between this row and HEAD.
    public let lane: Lane
    /// HEAD's row once this row is on top.
    public let headRow: Int
    /// The rows from the top down to HEAD as the layout produced them.
    private let rowsAboveHead: [GraphRow]

    /// Puts a row with `id` on top of `rows`, where HEAD is the row at `headIndex`.
    public static func insert(id: String, into rows: inout [GraphRow], headIndex: Int) -> WorkingDirectoryRow {
        let head = rows[headIndex]
        let lane = head.lane
        let original = Array(rows[0..<headIndex])
        let through = GraphEdge(fromLane: lane, toLane: lane, kind: .passThrough, color: head.color)
        for above in 0..<headIndex {
            let row = rows[above]
            rows[above] = GraphRow(commitID: row.commitID, lane: row.lane, color: row.color, isMerge: row.isMerge, edges: row.edges + [through], laneCount: row.laneCount)
        }
        let down = GraphEdge(fromLane: lane, toLane: lane, kind: .straight, color: head.color)
        rows.insert(GraphRow(commitID: id, lane: lane, color: head.color, isMerge: false, edges: [down], laneCount: lane + 1), at: 0)
        return WorkingDirectoryRow(lane: lane, headRow: headIndex + 1, rowsAboveHead: original)
    }

    /// Takes the row off `rows` again and gives the rows above HEAD back their own edges.
    public func remove(from rows: inout [GraphRow]) {
        rows.remove(at: 0)
        rows.replaceSubrange(0..<rowsAboveHead.count, with: rowsAboveHead)
    }
}
