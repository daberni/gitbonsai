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
    /// The working directory row appeared while commits were still streaming in.
    var onRowsShifted: (() -> Void)?
    /// HEAD moved: the rows were laid out again around it and the working directory row was put back.
    var onRowsRebuilt: (() -> Void)?

    /// Rebound when the tab moves to another worktree of the same repository.
    private(set) var repository: Repository
    private var layout = GraphLayout()
    /// The commit the current layout keeps the leftmost lane for.
    private var layoutHead: String?
    private var loadTask: Task<Void, Never>?
    /// While a refresh gathers its parts, the single redraw at its end replaces the per-part ones.
    private var isRefreshing = false
    private var loadedSummary = ""
    private var reachableFromHead: Set<String> = []
    /// Position among the real commits. The working directory row is not counted, so these stay valid when that row moves.
    private var commitIndexByID: [String: Int] = [:]
    /// Where the working directory row sits in the row arrays, and the rows from the top down to HEAD as the layout produced them.
    private var wipRow: Int?
    private var rowsBeforeWip: [GraphRow] = []
    /// The lane of the strand between the working directory row and HEAD, and HEAD's row.
    private(set) var wipStrand: (lane: Lane, headRow: Int)?
    /// The row that stands for where the working tree is: its uncommitted changes if there are any, otherwise HEAD.
    var currentRow: Int? { wipRow ?? headSHA.flatMap { rowIndex(of: $0) } }
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

    /// After a checkout or a worktree switch the commits are still the same: only HEAD, the working directory and the refs moved.
    /// So nothing is read from the log; the loaded commits are laid out again when HEAD sits on another commit.
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
        // HEAD's strand owns the leftmost lane, so a HEAD on another commit means another layout of the same commits.
        if headSHA != layoutHead { await relayout() }
        insertWipRow()
        computeReachability()
        onRowsRebuilt?()
        onMetadataChanged?()
        setStatus(([loadedSummary] + [note].compactMap { $0 } + ["Ansicht \(elapsed(since: start))"]).joined(separator: " · "))
        // The other worktrees' change counters are slow to gather and nothing waits for them.
        Task { await loadWorktreeStatuses() }
    }

    // MARK: Working directory row

    /// Uncommitted changes always show as the first row. The layout keeps the leftmost lane for HEAD, so the row sits in that lane
    /// and a dashed strand runs straight down to HEAD through the rows in between.
    private func insertWipRow() {
        guard wipRow == nil, !(status?.entries.isEmpty ?? true), let head = headSHA, let index = commitIndexByID[head], index < rows.count else { return }
        let headRow = rows[index]
        rowsBeforeWip = Array(rows[0..<index])
        let lane = headRow.lane
        for above in 0..<index {
            let row = rows[above]
            let through = GraphEdge(fromLane: lane, toLane: lane, kind: .passThrough, color: headRow.color)
            rows[above] = GraphRow(commitID: row.commitID, lane: row.lane, color: row.color, isMerge: row.isMerge, edges: row.edges + [through], laneCount: row.laneCount)
        }
        let now = Date()
        let down = GraphEdge(fromLane: lane, toLane: lane, kind: .straight, color: headRow.color)
        commits.insert(Commit(id: Self.wipID, parents: [head], authorName: "", authorEmail: "", authorDate: now, committerName: "", committerEmail: "", committerDate: now, subject: "", body: ""), at: 0)
        rows.insert(GraphRow(commitID: Self.wipID, lane: lane, color: headRow.color, isMerge: false, edges: [down], laneCount: lane + 1), at: 0)
        kinds.insert(.wip, at: 0)
        wipRow = 0
        wipStrand = (lane, index + 1)
    }

    /// Lays the loaded commits out again around a new HEAD, off the main thread. Nothing is read from git.
    private func relayout() async {
        let head = headSHA
        let input = commits.map { layoutCommit(for: $0) }
        let result = await Task.detached { () -> (GraphLayout, [GraphRow]) in
            var layout = GraphLayout(pinned: head)
            let rows = input.map { layout.append($0) }
            return (layout, rows)
        }.value
        layout = result.0
        rows = result.1
        layoutHead = head
        maxLaneCount = max(layout.maxLaneCount, 1)
    }

    private func removeWipRow() {
        guard wipRow != nil else { return }
        commits.remove(at: 0)
        rows.remove(at: 0)
        kinds.remove(at: 0)
        rows.replaceSubrange(0..<rowsBeforeWip.count, with: rowsBeforeWip)
        rowsBeforeWip = []
        wipRow = nil
        wipStrand = nil
    }

    /// Drops everything that was loaded and reads the repository again.
    func reload() {
        loadTask?.cancel()
        commits = []
        rows = []
        kinds = []
        commitIndexByID = [:]
        wipRow = nil
        rowsBeforeWip = []
        wipStrand = nil
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
            layout = GraphLayout(pinned: headSHA)
            layoutHead = headSHA
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
            let range = commits.count..<(commits.count + pending.count)
            let firstCommitIndex = commits.count - (wipRow == nil ? 0 : 1)
            for (offset, commit) in pending.enumerated() { commitIndexByID[commit.id] = firstCommitIndex + offset }
            commits.append(contentsOf: pending)
            rows.append(contentsOf: pendingRows)
            kinds.append(contentsOf: pendingKinds)
            maxLaneCount = max(layout.maxLaneCount, 1)
            pending.removeAll(keepingCapacity: true)
            pendingRows.removeAll(keepingCapacity: true)
            pendingKinds.removeAll(keepingCapacity: true)
            onRowsAppended?(range)
            if wipRow == nil {
                insertWipRow()
                // HEAD arrived in this batch: the new first row shifts every row that is already on screen.
                if wipRow != nil { onRowsShifted?() }
            }
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
