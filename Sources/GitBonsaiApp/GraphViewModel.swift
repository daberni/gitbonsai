import Foundation
import GitEngine
import GraphLayout

struct WorktreeInfo: Sendable, Identifiable {
    var id: String { worktree.path }
    let worktree: Worktree
    /// Nil when the worktree folder is missing or its status could not be read.
    let status: RepositoryStatus?
}

/// Owns everything one repository window shows: the streamed commit list with its layout, refs, stashes, worktrees and the working directory status.
///
/// Commits are appended in batches so the table inserts rows a few hundred at a time; the first batch is flushed immediately.
@MainActor
final class GraphViewModel {
    enum RowKind { case commit, merge, stash, wip }

    static let wipID = "WIP"

    private(set) var commits: [Commit] = []
    private(set) var rows: [GraphRow] = []
    private(set) var kinds: [RowKind] = []
    private(set) var refs: [Ref] = []
    private(set) var refsByCommit: [String: [Ref]] = [:]
    private(set) var stashes: [Stash] = []
    private(set) var stashesByCommit: [String: Stash] = [:]
    private(set) var worktrees: [WorktreeInfo] = []
    private(set) var status: RepositoryStatus?
    private(set) var lastFetch: Date?
    private(set) var statusText = "Loading…"
    private(set) var isLoading = false
    private(set) var maxLaneCount = 1

    var onRowsAppended: ((_ range: Range<Int>) -> Void)?
    /// Refs, reachability, worktrees or status changed: visible rows and the sidebar need a redraw.
    var onMetadataChanged: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?
    /// All rows were dropped before a reload; the table has to forget them.
    var onReset: (() -> Void)?
    /// HEAD moved: the working directory row was taken out and put back above the new HEAD, every other row is unchanged.
    var onRowsRebuilt: (() -> Void)?

    /// Rebound when the tab moves to another worktree of the same repository.
    private(set) var repository: Repository
    private var layout = GraphLayout()
    private var loadTask: Task<Void, Never>?
    /// While a refresh gathers its parts, the single redraw at its end replaces the per-part ones.
    private var isRefreshing = false
    private var loadedSummary = ""
    private var reachableFromHead: Set<String> = []
    /// Position among the real commits. The working directory row is not counted, so these stay valid when that row moves.
    private var commitIndexByID: [String: Int] = [:]
    /// Where the working directory row currently sits in the row arrays, and the HEAD row as the layout produced it.
    private var wipRow: Int?
    private var headRowBeforeWip: GraphRow?
    /// Index and untracked helper commits of stashes. They follow their stash in topological order and are skipped.
    private var hiddenCommitIDs: Set<String> = []

    init(repositoryPath: String) {
        repository = Repository(path: repositoryPath)
    }

    var headSHA: String? { status?.branch.headSHA }
    var currentBranch: String? { status?.branch.branch }

    /// Full ref names of branches checked out in a worktree other than this window's.
    var branchesInOtherWorktrees: [String: Worktree] {
        var result: [String: Worktree] = [:]
        for info in worktrees {
            guard let branch = info.worktree.branch, !isCurrent(info.worktree) else { continue }
            result[branch] = info.worktree
        }
        return result
    }

    enum CheckoutOutcome {
        case done
        /// Git refused because local changes would be overwritten; carries git's message.
        case blockedByLocalChanges(String)
        case failed(String)
    }

    /// The working tree this tab shows, as opposed to the repository's other worktrees.
    func isCurrent(_ worktree: Worktree) -> Bool {
        URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: repository.path).resolvingSymlinksInPath().path
    }

    /// The repository's name is the folder of its main worktree, whichever worktree the tab shows.
    var repositoryName: String {
        let main = worktrees.first { $0.worktree.isMain }?.worktree.path ?? repository.path
        return URL(fileURLWithPath: main).lastPathComponent
    }

    func checkout(_ target: CheckoutTarget, carryingChanges: Bool = false) async -> CheckoutOutcome {
        setStatus("Wechsle …")
        let start = ContinuousClock.now
        do {
            if carryingChanges { try await repository.checkoutCarryingChanges(target) } else { try await repository.checkout(target) }
            await refresh(note: "git switch \(elapsed(since: start))")
            return .done
        } catch let error as GitError {
            // A failed attempt may still have moved things, for instance when the carried changes conflict on the target.
            await refresh(note: nil)
            let message = error.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return error.isBlockedByLocalChanges && !carryingChanges ? .blockedByLocalChanges(message) : .failed(message)
        } catch {
            return .failed("\(error)")
        }
    }

    /// Shows another worktree of the same repository in place.
    func switchWorktree(to path: String) {
        repository = Repository(path: path, gitPath: repository.runner.gitPath)
        Task { await refresh(note: nil) }
    }

    /// After a checkout or a worktree switch the commits and their layout are still the same: only HEAD, the working directory and the refs moved.
    /// So nothing is read from the log and nothing is laid out again; the working directory row moves and the marks are redrawn.
    func refresh(note: String?) async {
        guard !isLoading else { reload(); return }
        let start = ContinuousClock.now
        isRefreshing = true
        let knownStashes = Set(stashesByCommit.keys)
        async let newStatus = try? repository.status()
        async let stashesTask: Void = loadStashes()
        async let refsTask: Void = loadRefs()
        async let worktreesTask: Void = loadWorktreeList()
        status = await newStatus
        _ = await (stashesTask, refsTask, worktreesTask)
        isRefreshing = false
        guard Set(stashesByCommit.keys) == knownStashes else {
            // A new or dropped stash changes the set of commits; that needs the log.
            reload()
            return
        }
        removeWipRow()
        insertWipRow()
        computeReachability()
        onRowsRebuilt?()
        onMetadataChanged?()
        setStatus(([loadedSummary] + [note].compactMap { $0 } + ["Ansicht \(elapsed(since: start))"]).joined(separator: " · "))
        // The other worktrees' change counters are slow to gather and nothing waits for them.
        Task { await loadWorktreeStatuses() }
    }

    // MARK: Working directory row

    /// Uncommitted changes show as a row directly above HEAD. The row is not part of the lane layout: it is derived from the HEAD row and the row above it,
    /// so it can move with HEAD without laying out a single commit again.
    private func insertWipRow() {
        guard wipRow == nil, !(status?.entries.isEmpty ?? true), let head = headSHA, let index = commitIndexByID[head], index < rows.count else { return }
        let headRow = rows[index]
        // Lanes that run from the row above into the HEAD row keep running through the new row.
        var passing: [Lane: Int] = [:]
        if index > 0 {
            for edge in rows[index - 1].edges where edge.kind != .fromChild { passing[edge.toLane] = edge.color }
        }
        let headHasChildren = passing[headRow.lane] != nil
        // On a branch tip the row sits on HEAD's own strand; otherwise it hangs off to the right of everything and joins HEAD from there.
        let lane = headHasChildren ? max(headRow.laneCount, (passing.keys.max() ?? -1) + 1) : headRow.lane
        var edges = passing.sorted { $0.key < $1.key }.map { GraphEdge(fromLane: $0.key, toLane: $0.key, kind: .passThrough, color: $0.value) }
        edges.append(GraphEdge(fromLane: lane, toLane: lane, kind: .straight, color: headRow.color))
        let laneCount = max(headRow.laneCount, lane + 1)
        if headHasChildren {
            let joined = headRow.edges + [GraphEdge(fromLane: lane, toLane: headRow.lane, kind: .fromChild, color: headRow.color)]
            rows[index] = GraphRow(commitID: headRow.commitID, lane: headRow.lane, color: headRow.color, isMerge: headRow.isMerge, edges: joined, laneCount: laneCount)
        }
        let now = Date()
        commits.insert(Commit(id: Self.wipID, parents: [head], authorName: "", authorEmail: "", authorDate: now, committerName: "", committerEmail: "", committerDate: now, subject: "", body: ""), at: index)
        rows.insert(GraphRow(commitID: Self.wipID, lane: lane, color: headRow.color, isMerge: false, edges: edges, laneCount: laneCount), at: index)
        kinds.insert(.wip, at: index)
        wipRow = index
        headRowBeforeWip = headRow
        maxLaneCount = max(maxLaneCount, laneCount)
    }

    private func removeWipRow() {
        guard let index = wipRow else { return }
        commits.remove(at: index)
        rows.remove(at: index)
        kinds.remove(at: index)
        if let original = headRowBeforeWip { rows[index] = original }
        wipRow = nil
        headRowBeforeWip = nil
        maxLaneCount = max(layout.maxLaneCount, 1)
    }

    /// Drops everything that was loaded and reads the repository again.
    func reload() {
        loadTask?.cancel()
        commits = []
        rows = []
        kinds = []
        commitIndexByID = [:]
        wipRow = nil
        headRowBeforeWip = nil
        hiddenCommitIDs = []
        reachableFromHead = []
        maxLaneCount = 1
        layout = GraphLayout()
        onReset?()
        load()
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            status = try? await repository.status()
            await loadStashes()
            async let refsTask: Void = loadRefs()
            async let worktreesTask: Void = loadWorktrees()
            async let fetchTask: Void = loadLastFetch()
            await streamLog()
            _ = await (refsTask, worktreesTask, fetchTask)
            // A reload that started meanwhile owns the state now.
            if Task.isCancelled { return }
            computeReachability()
            isLoading = false
            onMetadataChanged?()
            setStatus(statusText)
        }
    }

    func rowIndex(of commitID: String) -> Int? {
        if commitID == Self.wipID { return wipRow }
        guard let index = commitIndexByID[commitID] else { return nil }
        if let wipRow, index >= wipRow { return index + 1 }
        return index
    }

    func isReachableFromHead(_ commitID: String) -> Bool {
        reachableFromHead.isEmpty || reachableFromHead.contains(commitID)
    }

    func fetch() async {
        setStatus("git fetch --all --prune …")
        do {
            _ = try await repository.runner.runWrite(["fetch", "--all", "--prune"])
            await loadLastFetch()
            await loadRefs()
            onMetadataChanged?()
            setStatus("Fetch abgeschlossen")
        } catch {
            setStatus("fetch fehlgeschlagen: \(error)")
        }
    }

    private func loadRefs() async {
        do {
            let loaded = try await repository.refs()
            var grouped: [String: [Ref]] = [:]
            for ref in loaded { grouped[ref.target, default: []].append(ref) }
            refs = loaded
            refsByCommit = grouped
            if !isRefreshing { onMetadataChanged?() }
        } catch {
            setStatus("refs failed: \(error)")
        }
    }

    private func loadStashes() async {
        guard let loaded = try? await repository.stashes() else { return }
        stashes = loaded
        stashesByCommit = Dictionary(loaded.map { ($0.commitID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func loadWorktrees() async {
        await loadWorktreeList()
        await loadWorktreeStatuses()
    }

    /// The list alone is cheap. Counters that are already known are kept until the fresh ones arrive.
    private func loadWorktreeList() async {
        guard let list = try? await repository.worktrees() else { return }
        let known = Dictionary(worktrees.map { ($0.worktree.path, $0.status) }, uniquingKeysWith: { first, _ in first })
        worktrees = list.map { WorktreeInfo(worktree: $0, status: known[$0.path] ?? nil) }
        if !isRefreshing { onMetadataChanged?() }
    }

    private func loadWorktreeStatuses() async {
        let list = worktrees.map(\.worktree)
        let gitPath = repository.runner.gitPath
        let infos = await withTaskGroup(of: (Int, WorktreeInfo).self) { group in
            for (index, worktree) in list.enumerated() {
                group.addTask {
                    let status = worktree.isBare || worktree.isPrunable ? nil : try? await Repository(path: worktree.path, gitPath: gitPath).status()
                    return (index, WorktreeInfo(worktree: worktree, status: status))
                }
            }
            var collected: [(Int, WorktreeInfo)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        // A switch that happened meanwhile brought its own list; these counters belong to the old one.
        guard infos.map(\.worktree) == worktrees.map(\.worktree) else { return }
        worktrees = infos
        onMetadataChanged?()
    }

    /// The modification date of FETCH_HEAD is the time of the last fetch; git offers no command for it.
    private func loadLastFetch() async {
        guard let result = try? await repository.runner.run(["rev-parse", "--git-common-dir"]) else { return }
        var directory = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !directory.hasPrefix("/") { directory = repository.path + "/" + directory }
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory + "/FETCH_HEAD")
        lastFetch = attributes?[.modificationDate] as? Date
    }

    /// A stash commit keeps only its base parent in the graph: the index and untracked helper commits would otherwise appear as a merge with two invisible strands.
    private func layoutCommit(for commit: Commit) -> Commit {
        guard stashesByCommit[commit.id] != nil, commit.parents.count > 1 else { return commit }
        return Commit(id: commit.id, parents: [commit.parents[0]], authorName: commit.authorName, authorEmail: commit.authorEmail, authorDate: commit.authorDate, committerName: commit.committerName, committerEmail: commit.committerEmail, committerDate: commit.committerDate, subject: commit.subject, body: commit.body)
    }

    private func streamLog() async {
        let start = ContinuousClock.now
        var pending: [Commit] = []
        var pendingRows: [GraphRow] = []
        var pendingKinds: [RowKind] = []
        var lastFlush = ContinuousClock.now
        var flushedFirst = false
        func add(_ commit: Commit, kind: RowKind) {
            pendingRows.append(layout.append(layoutCommit(for: commit)))
            pending.append(commit)
            pendingKinds.append(kind)
        }
        func flush() {
            guard !pending.isEmpty else { return }
            var range = commits.count..<(commits.count + pending.count)
            let firstCommitIndex = commits.count - (wipRow == nil ? 0 : 1)
            for (offset, commit) in pending.enumerated() { commitIndexByID[commit.id] = firstCommitIndex + offset }
            commits.append(contentsOf: pending)
            rows.append(contentsOf: pendingRows)
            kinds.append(contentsOf: pendingKinds)
            maxLaneCount = max(maxLaneCount, layout.maxLaneCount)
            pending.removeAll(keepingCapacity: true)
            pendingRows.removeAll(keepingCapacity: true)
            pendingKinds.removeAll(keepingCapacity: true)
            if wipRow == nil {
                insertWipRow()
                // HEAD arrived in this batch, so the extra row lies inside it.
                if wipRow != nil { range = range.lowerBound..<(range.upperBound + 1) }
            }
            onRowsAppended?(range)
        }
        do {
            var options = LogOptions()
            options.extraArguments = Array(stashesByCommit.keys)
            for try await commit in repository.log(options) {
                if Task.isCancelled { return }
                if hiddenCommitIDs.contains(commit.id) { continue }
                if stashesByCommit[commit.id] != nil { hiddenCommitIDs.formUnion(commit.parents.dropFirst()) }
                let kind: RowKind = stashesByCommit[commit.id] != nil ? .stash : commit.isMerge ? .merge : .commit
                add(commit, kind: kind)
                if !flushedFirst || pending.count >= 500 || lastFlush.duration(to: .now) > .milliseconds(100) {
                    flush()
                    flushedFirst = true
                    lastFlush = .now
                    setStatus("\(commits.count) Commits · \(elapsed(since: start))")
                }
            }
            if Task.isCancelled { return }
            flush()
            loadedSummary = "\(commits.count) Commits · \(layout.maxLaneCount) Lanes · \(stashes.count) Stashes · geladen in \(elapsed(since: start))"
            setStatus(loadedSummary)
        } catch is CancellationError {
        } catch {
            flush()
            setStatus("git log fehlgeschlagen: \(error)")
        }
    }

    /// Walks parents from HEAD over the loaded commits. Linear in the history size.
    private func computeReachability() {
        guard let head = headSHA else { return }
        var parentsByID: [String: [String]] = [:]
        parentsByID.reserveCapacity(commits.count)
        for commit in commits { parentsByID[commit.id] = commit.parents }
        var seen: Set<String> = [head, Self.wipID]
        var stack = [head]
        while let id = stack.popLast() {
            for parent in parentsByID[id] ?? [] where seen.insert(parent).inserted { stack.append(parent) }
        }
        reachableFromHead = seen
    }

    private func setStatus(_ text: String) {
        statusText = text
        onStatusChanged?(text)
    }

    private func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return milliseconds < 1000 ? String(format: "%.0f ms", milliseconds) : String(format: "%.2f s", milliseconds / 1000)
    }
}
