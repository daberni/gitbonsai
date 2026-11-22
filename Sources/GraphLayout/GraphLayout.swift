import Foundation
import GitEngine

/// Index of a vertical lane in the graph, 0 is leftmost.
public typealias Lane = Int

public enum EdgeKind: Sendable, Hashable {
    /// Continues the same lane from this row's node to the next row.
    case straight
    /// Leaves this row's node toward a parent in another lane (merge: node has several parents).
    case toParent
    /// A lane that passes through this row without a node.
    case passThrough
    /// A child strand arriving at this row's node from another lane. Drawn in the upper half of
    /// the row, from the top of `fromLane` to the node in `toLane`; the previous row's pass-through
    /// edge for `fromLane` ends where this edge starts.
    case fromChild
}

/// One drawable connection between this row and the next. Coordinates are lanes; the row below is implied.
public struct GraphEdge: Sendable, Hashable {
    public let fromLane: Lane
    public let toLane: Lane
    public let kind: EdgeKind
    /// Stable color index for the branch strand this edge belongs to.
    public let color: Int

    public init(fromLane: Lane, toLane: Lane, kind: EdgeKind, color: Int) {
        self.fromLane = fromLane
        self.toLane = toLane
        self.kind = kind
        self.color = color
    }
}

/// Layout result for one commit. Rows are produced in the same order commits are appended.
public struct GraphRow: Sendable, Hashable, Identifiable {
    public var id: String { commitID }
    public let commitID: String
    public let lane: Lane
    public let color: Int
    public let isMerge: Bool
    /// Edges of this row: `.fromChild` edges end at the node, every other kind leaves toward the row below.
    public let edges: [GraphEdge]
    /// Number of lane slots the row needs for drawing: the larger of the occupied slots entering and leaving the row.
    public let laneCount: Int

    public init(commitID: String, lane: Lane, color: Int, isMerge: Bool, edges: [GraphEdge], laneCount: Int) {
        self.commitID = commitID
        self.lane = lane
        self.color = color
        self.isMerge = isMerge
        self.edges = edges
        self.laneCount = laneCount
    }
}

/// Incremental lane layout for a commit list in topological order (children before parents).
///
/// Append commits one at a time as they arrive from `git log`; each append returns the finished
/// row for that commit. The layout keeps only the set of active lanes between rows, so memory
/// per row is constant and 100k commits lay out in well under a second.
public struct GraphLayout: Sendable {
    public private(set) var rows: [GraphRow] = []
    public private(set) var maxLaneCount: Int = 0

    private struct ActiveLane {
        var expected: String
        var color: Int
    }

    /// Lane slots between the last row and the next one; nil slots are free for reuse.
    private var lanes: [ActiveLane?] = []
    /// Lane indices waiting for a given parent SHA, removed as soon as that commit arrives.
    private var lanesExpecting: [String: [Lane]] = [:]
    private var rowIndexByCommitID: [String: Int] = [:]
    private var nextColor = 0
    /// The pinned commit while the leftmost lane is still only held free for it and nothing has drawn into that lane yet.
    private var reservedFor: String?

    public init() {}

    /// Keeps the leftmost lane for `pinned`, the checked-out commit: it and its first-parent ancestors always sit in lane 0, in the first strand color.
    /// Above the pinned commit the lane stays empty; children of the pinned commit join it from their own lanes.
    public init(pinned: String?) {
        guard let pinned else { return }
        lanes = [ActiveLane(expected: pinned, color: 0)]
        lanesExpecting[pinned] = [0]
        nextColor = 1
        reservedFor = pinned
    }

    /// Row of an already appended commit, for selection and scrolling.
    public func row(for commitID: String) -> GraphRow? {
        rowIndexByCommitID[commitID].map { rows[$0] }
    }

    @discardableResult
    public mutating func append(_ commit: Commit) -> GraphRow {
        if let existing = rowIndexByCommitID[commit.id] {
            return rows[existing]
        }

        let occupiedBefore = lanes.count
        var edges: [GraphEdge] = []
        if commit.id == reservedFor { reservedFor = nil }

        let waiting = (lanesExpecting.removeValue(forKey: commit.id) ?? []).sorted()
        let lane: Lane
        let color: Int
        if let first = waiting.first, let active = lanes[first] {
            lane = first
            color = active.color
            for child in waiting.dropFirst() {
                if let childLane = lanes[child] {
                    edges.append(GraphEdge(fromLane: child, toLane: lane, kind: .fromChild, color: childLane.color))
                }
                lanes[child] = nil
            }
        } else {
            lane = allocateLane(after: -1)
            color = nextColor
            nextColor += 1
            lanes[lane] = ActiveLane(expected: commit.id, color: color)
        }

        for (index, active) in lanes.enumerated() where index != lane {
            guard let active else { continue }
            if index == 0, reservedFor != nil { continue }
            edges.append(GraphEdge(fromLane: index, toLane: index, kind: .passThrough, color: active.color))
        }

        var parents: [String] = []
        for parent in commit.parents where !parents.contains(parent) {
            parents.append(parent)
        }

        if let firstParent = parents.first {
            lanes[lane] = ActiveLane(expected: firstParent, color: color)
            lanesExpecting[firstParent, default: []].append(lane)
            edges.append(GraphEdge(fromLane: lane, toLane: lane, kind: .straight, color: color))
        } else {
            lanes[lane] = nil
        }

        for parent in parents.dropFirst() {
            if let target = lanesExpecting[parent]?.min(), let active = lanes[target] {
                // A merge that reaches the pinned commit draws into the held lane, so from here on the lane is a visible strand.
                if parent == reservedFor { reservedFor = nil }
                edges.append(GraphEdge(fromLane: lane, toLane: target, kind: .toParent, color: active.color))
            } else {
                let target = allocateLane(after: lane)
                let parentColor = nextColor
                nextColor += 1
                lanes[target] = ActiveLane(expected: parent, color: parentColor)
                lanesExpecting[parent, default: []].append(target)
                edges.append(GraphEdge(fromLane: lane, toLane: target, kind: .toParent, color: parentColor))
            }
        }

        trimTrailingFreeLanes()
        edges.sort { ($0.fromLane, $0.toLane) < ($1.fromLane, $1.toLane) }

        let laneCount = max(occupiedBefore, lanes.count, lane + 1)
        maxLaneCount = max(maxLaneCount, laneCount)
        let row = GraphRow(commitID: commit.id, lane: lane, color: color, isMerge: parents.count > 1, edges: edges, laneCount: laneCount)
        rowIndexByCommitID[commit.id] = rows.count
        rows.append(row)
        return row
    }

    public mutating func append<S: Sequence>(contentsOf commits: S) where S.Element == Commit {
        for commit in commits { append(commit) }
    }

    /// First free slot right of `after`, otherwise a new slot at the end.
    private mutating func allocateLane(after: Lane) -> Lane {
        var index = after + 1
        while index < lanes.count {
            if lanes[index] == nil { return index }
            index += 1
        }
        lanes.append(nil)
        return lanes.count - 1
    }

    private mutating func trimTrailingFreeLanes() {
        while let last = lanes.last, last == nil {
            lanes.removeLast()
        }
    }
}
