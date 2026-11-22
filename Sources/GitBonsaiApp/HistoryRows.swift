import Foundation
import GitEngine
import GraphLayout

/// The history table's content: commits, their graph rows and row kinds side by side, with the working directory row on top while there are uncommitted changes.
struct HistoryRows {
    static let wipID = "WIP"

    private(set) var commits: [Commit] = []
    private(set) var rows: [GraphRow] = []
    private(set) var kinds: [GraphViewModel.RowKind] = []
    /// Position among the real commits. The working directory row is not counted, so these stay valid when that row moves.
    private var commitIndexByID: [String: Int] = [:]
    private(set) var workingDirectory: WorkingDirectoryRow?

    /// Where the working directory row sits in the row arrays.
    var wipRow: Int? { workingDirectory == nil ? nil : 0 }

    /// The real commits, without the working directory row.
    var commitCount: Int { commits.count - (wipRow == nil ? 0 : 1) }

    func rowIndex(of commitID: String) -> Int? {
        if commitID == Self.wipID { return wipRow }
        guard let index = commitIndexByID[commitID] else { return nil }
        if let wipRow, index >= wipRow { return index + 1 }
        return index
    }

    /// Appends a batch below the loaded rows and returns the row range it took.
    mutating func append(_ newCommits: [Commit], rows newRows: [GraphRow], kinds newKinds: [GraphViewModel.RowKind]) -> Range<Int> {
        let range = commits.count..<(commits.count + newCommits.count)
        let firstCommitIndex = commits.count - (wipRow == nil ? 0 : 1)
        for (offset, commit) in newCommits.enumerated() { commitIndexByID[commit.id] = firstCommitIndex + offset }
        commits.append(contentsOf: newCommits)
        rows.append(contentsOf: newRows)
        kinds.append(contentsOf: newKinds)
        return range
    }

    /// Drops commits that left the history; their rows have to be laid out again afterwards. Only valid without the working directory row.
    mutating func remove(_ commitIDs: Set<String>) {
        let kept = commits.indices.filter { !commitIDs.contains(commits[$0].id) }
        commits = kept.map { commits[$0] }
        rows = kept.map { rows[$0] }
        kinds = kept.map { kinds[$0] }
        commitIndexByID = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($1.id, $0) })
    }

    /// Replaces the graph rows with another layout of the same commits. Only valid without the working directory row.
    mutating func replaceRows(_ newRows: [GraphRow]) {
        rows = newRows
    }

    /// Puts the working directory row on top when HEAD is loaded. Returns whether it is there afterwards.
    @discardableResult
    mutating func insertWorkingDirectoryRow(head: String) -> Bool {
        guard workingDirectory == nil else { return true }
        guard let index = commitIndexByID[head], index < rows.count else { return false }
        workingDirectory = WorkingDirectoryRow.insert(id: Self.wipID, into: &rows, headIndex: index)
        let now = Date()
        commits.insert(Commit(id: Self.wipID, parents: [head], authorName: "", authorEmail: "", authorDate: now, committerName: "", committerEmail: "", committerDate: now, subject: "", body: ""), at: 0)
        kinds.insert(.wip, at: 0)
        return true
    }

    mutating func removeWorkingDirectoryRow() {
        guard let workingDirectory else { return }
        workingDirectory.remove(from: &rows)
        commits.remove(at: 0)
        kinds.remove(at: 0)
        self.workingDirectory = nil
    }

    /// Walks parents from HEAD over the loaded commits. Linear in the history size.
    func reachable(from head: String) -> Set<String> {
        var parentsByID: [String: [String]] = [:]
        parentsByID.reserveCapacity(commits.count)
        for commit in commits { parentsByID[commit.id] = commit.parents }
        var seen: Set<String> = [head, Self.wipID]
        var stack = [head]
        while let id = stack.popLast() {
            for parent in parentsByID[id] ?? [] where seen.insert(parent).inserted { stack.append(parent) }
        }
        return seen
    }
}
