import Foundation
import GitEngine
import GraphLayout

/// Owns everything one repository window shows: the streamed commit list with its layout, refs, stashes, worktrees and the working directory status.
///
/// It coordinates the parts: `LogLoader` streams the history into `HistoryRows`, `RefLoader` and `WorktreeLoader` read the rest.
@MainActor
final class GraphViewModel {
    enum RowKind { case commit, merge, stash, wip }

    /// Which row the history shows once a refresh rebuilt its rows.
    enum Focus {
        /// The selected commit stays selected at the same place on screen, as long as it is still in the history.
        case keepSelection
        /// The action moved the working tree on purpose, such as a checkout: the uncommitted changes or HEAD are selected and HEAD is brought into view.
        case current
    }

    static let wipID = HistoryRows.wipID

    private var history = HistoryRows()
    var commits: [Commit] { history.commits }
    var rows: [GraphRow] { history.rows }
    var kinds: [RowKind] { history.kinds }
    private(set) var refs: [Ref] = [] { didSet { sidebarChanges += 1 } }
    private(set) var refsByCommit: [String: [Ref]] = [:]
    private(set) var stashes: [Stash] = [] { didSet { sidebarChanges += 1 } }
    private(set) var stashesByCommit: [String: Stash] = [:]
    private(set) var worktrees: [WorktreeInfo] = [] { didSet { sidebarChanges += 1 } }
    private(set) var status: RepositoryStatus? { didSet { sidebarChanges += 1 } }
    /// The folder of the repository's main worktree, whichever worktree the tab shows.
    let repositoryName: String
    private(set) var lastFetch: Date?
    private(set) var isFetching = false
    private(set) var statusText = "Loading…"
    private(set) var isLoading = false
    private(set) var maxLaneCount = 1

    var onRowsAppended: ((_ range: Range<Int>) -> Void)?
    /// Refs, reachability, worktrees or status changed: visible rows and the sidebar need a redraw.
    var onMetadataChanged: (() -> Void)?
    var onStatusChanged: ((String) -> Void)?
    /// All rows were dropped before a reload; the table has to forget them and, once the reload finished, show the focus.
    var onReset: ((Focus) -> Void)?
    /// The working directory row appeared while commits were still streaming in.
    var onRowsShifted: (() -> Void)?
    /// A refresh after a write rebuilt the rows in place: commits may have left, HEAD may have moved and the working directory row was put back.
    var onRowsRebuilt: ((Focus) -> Void)?

    /// Rebound when the tab moves to another worktree of the same repository.
    private(set) var repository: Repository
    /// The commit the current layout keeps the leftmost lane for.
    private var layoutHead: String?
    private var loadTask: Task<Void, Never>?
    /// While a refresh gathers its parts, the single redraw at its end replaces the per-part ones.
    private var isRefreshing = false
    private var loadDuration = ""
    /// Counted live, because a refresh can drop commits and lay them out again.
    private var loadedSummary: String { "\(history.commitCount) Commits · \(maxLaneCount) Lanes · \(stashes.count) Stashes · geladen in \(loadDuration)" }
    /// The note of a refresh that had to read the log again, such as after a rebase; the reload shows it once it has finished.
    private var noteAfterReload: String?
    private var reachableFromHead: Set<String> = []
    private var sidebarChanges = 0
    private var hasSidebarContent = false

    /// Changes whenever something the sidebar shows changed. Nil until the first load knows the refs, the worktrees and their counters, so the sidebar is built once with all of them.
    var sidebarRevision: Int? { hasSidebarContent ? sidebarChanges : nil }

    /// The lane of the strand between the working directory row and HEAD, and HEAD's row.
    var wipStrand: (lane: Lane, headRow: Int)? { history.workingDirectory.map { ($0.lane, $0.headRow) } }
    /// The row that stands for where the working tree is: its uncommitted changes if there are any, otherwise HEAD.
    var currentRow: Int? { history.wipRow ?? headSHA.flatMap { rowIndex(of: $0) } }

    init(location: RepositoryLocation) {
        repository = Repository(path: location.root)
        repositoryName = location.name
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
        /// The switch happened, but the carried changes conflict there; they stay in the stash `CarriedChangesConflict` names.
        case changesLeftInStash(CarriedChangesConflict)
        case failed(String)
    }

    /// The working tree this tab shows, as opposed to the repository's other worktrees.
    func isCurrent(_ worktree: Worktree) -> Bool {
        URL(fileURLWithPath: worktree.path).resolvingSymlinksInPath().path == URL(fileURLWithPath: repository.path).resolvingSymlinksInPath().path
    }

    func rowIndex(of commitID: String) -> Int? {
        history.rowIndex(of: commitID)
    }

    func isReachableFromHead(_ commitID: String) -> Bool {
        reachableFromHead.isEmpty || reachableFromHead.contains(commitID)
    }

    // MARK: Actions

    func checkout(_ target: CheckoutTarget) async -> CheckoutOutcome {
        setStatus("Wechsle …")
        let start = ContinuousClock.now
        do {
            try await repository.checkout(target)
            await refresh(note: "git switch \(elapsed(since: start))", focus: .current)
            return .done
        } catch let conflict as CarriedChangesConflict {
            await refresh(note: nil, focus: .current)
            return .changesLeftInStash(conflict)
        } catch let error as GitError {
            // A failed attempt may still have moved things, for instance a fast-forward that switched but could not move the branch.
            await refresh(note: nil)
            return .failed(error.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failed("\(error)")
        }
    }

    /// Shows another worktree of the same repository in place.
    func switchWorktree(to path: String) {
        repository = Repository(path: path, gitPath: repository.runner.gitPath)
        Task { await refresh(note: nil, focus: .current) }
    }

    /// Runs one fetch variant; the status line names the command and its duration. Returns git's error so the caller can show its message.
    func fetch(_ variant: FetchVariant) async -> Error? {
        setStatus("\(variant.commandLine) …")
        isFetching = true
        defer { isFetching = false }
        let start = ContinuousClock.now
        do {
            try await repository.fetch(variant)
            await loadLastFetch()
            await loadRefs()
            onMetadataChanged?()
            setStatus("\(variant.commandLine) · \(elapsed(since: start))")
            return nil
        } catch {
            let message = (error as? GitError)?.stderr.split(separator: "\n").first.map(String.init) ?? "\(error)"
            setStatus("\(variant.commandLine) fehlgeschlagen nach \(elapsed(since: start)): \(message)")
            return error
        }
    }

    // MARK: Loading

    /// Drops everything that was loaded and reads the repository again.
    func reload(focus: Focus = .keepSelection) {
        loadTask?.cancel()
        history = HistoryRows()
        reachableFromHead = []
        maxLaneCount = 1
        onReset?(focus)
        load()
    }

    func load() {
        loadTask?.cancel()
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            status = try? await repository.status()
            layoutHead = headSHA
            await loadStashes()
            async let sidebarTask: Void = loadSidebarContent()
            async let fetchTask: Void = loadLastFetch()
            await streamLog()
            _ = await (sidebarTask, fetchTask)
            // A reload that started meanwhile owns the state now.
            if Task.isCancelled { return }
            computeReachability()
            isLoading = false
            onMetadataChanged?()
            setStatus(statusText)
        }
    }

    /// After a checkout, a reset or a worktree switch the commits are mostly the same: HEAD, the working directory and the refs moved.
    /// So nothing is read from the log as long as every tip is loaded: commits no tip reaches anymore leave, and the rest are laid out again when HEAD or the commits changed.
    /// The history keeps its selection unless `focus` asks for the current row.
    func refresh(note: String?, focus: Focus = .keepSelection) async {
        guard !isLoading else {
            noteAfterReload = note ?? noteAfterReload
            reload(focus: focus)
            return
        }
        let start = ContinuousClock.now
        isRefreshing = true
        async let newStatus = try? repository.status()
        async let stashesTask: Void = loadStashes()
        async let refsTask: Void = loadRefs()
        async let worktreesTask: Void = loadWorktreeList()
        status = await newStatus
        _ = await (stashesTask, refsTask, worktreesTask)
        isRefreshing = false
        history.removeWorkingDirectoryRow()
        // A new commit, stash or a worktree HEAD that no branch contains is not loaded and needs the log.
        let tips = HistoryRefresh.tips(refs: refs, head: headSHA, stashCommits: stashesByCommit.keys)
        let loaded = history.commits
        let plan = await Task.detached { HistoryRefresh.plan(loaded: loaded, tips: tips) }.value
        guard case .keep(let dropping) = plan else {
            noteAfterReload = note ?? noteAfterReload
            reload(focus: focus)
            return
        }
        if !dropping.isEmpty { history.remove(dropping) }
        // HEAD's strand owns the leftmost lane, so a HEAD on another commit means another layout of the same commits.
        if headSHA != layoutHead || !dropping.isEmpty { await relayout() }
        insertWipRow()
        computeReachability()
        onRowsRebuilt?(focus)
        onMetadataChanged?()
        setStatus(([loadedSummary] + [note].compactMap { $0 } + ["Ansicht \(elapsed(since: start))"]).joined(separator: " · "))
        // The other worktrees' change counters are slow to gather and nothing waits for them.
        Task { await loadWorktreeStatuses() }
    }

    private func streamLog() async {
        let start = ContinuousClock.now
        let loader = LogLoader(repository: repository, stashesByCommit: stashesByCommit, head: layoutHead)
        let outcome = await loader.stream(onBatch: { batch in
            let range = history.append(batch.commits, rows: batch.rows, kinds: batch.kinds)
            maxLaneCount = batch.maxLaneCount
            onRowsAppended?(range)
            if history.wipRow == nil {
                insertWipRow()
                // HEAD arrived in this batch: the new first row shifts every row that is already on screen.
                if history.wipRow != nil { onRowsShifted?() }
            }
        }, onProgress: {
            setStatus("\(commits.count) Commits · \(elapsed(since: start))")
        })
        switch outcome {
        case .finished:
            loadDuration = elapsed(since: start)
            setStatus(([loadedSummary] + [noteAfterReload].compactMap { $0 }).joined(separator: " · "))
            noteAfterReload = nil
        case .cancelled:
            break
        case .failed(let error):
            setStatus("git log fehlgeschlagen: \(error)")
        }
    }

    /// Lays the loaded commits out again around a new HEAD. Nothing is read from git.
    private func relayout() async {
        let head = headSHA
        let result = await LogLoader.relayout(commits, head: head, stashesByCommit: stashesByCommit)
        history.replaceRows(result.rows)
        layoutHead = head
        maxLaneCount = result.maxLaneCount
    }

    /// Uncommitted changes always show as the first row.
    private func insertWipRow() {
        guard !(status?.entries.isEmpty ?? true), let head = headSHA else { return }
        history.insertWorkingDirectoryRow(head: head)
    }

    private func computeReachability() {
        guard let head = headSHA else { return }
        reachableFromHead = history.reachable(from: head)
    }

    private func loadRefs() async {
        do {
            (refs, refsByCommit) = try await RefLoader.refs(of: repository)
            if !isRefreshing { onMetadataChanged?() }
        } catch {
            setStatus("refs failed: \(error)")
        }
    }

    private func loadStashes() async {
        guard let loaded = await RefLoader.stashes(of: repository) else { return }
        (stashes, stashesByCommit) = loaded
    }

    private func loadLastFetch() async {
        do { lastFetch = try await RefLoader.lastFetch(of: repository) } catch {}
    }

    /// Refs, the worktree list and the worktrees' counters side by side, without waiting for the log.
    private func loadSidebarContent() async {
        async let refsTask: Void = loadRefs()
        async let worktreesTask: Void = loadWorktrees()
        _ = await (refsTask, worktreesTask)
        if Task.isCancelled { return }
        hasSidebarContent = true
        onMetadataChanged?()
    }

    private func loadWorktrees() async {
        await loadWorktreeList()
        await loadWorktreeStatuses()
    }

    private func loadWorktreeList() async {
        guard let list = await WorktreeLoader.list(of: repository, keeping: worktrees) else { return }
        worktrees = list
        if !isRefreshing { onMetadataChanged?() }
    }

    private func loadWorktreeStatuses() async {
        let infos = await WorktreeLoader.statuses(of: worktrees.map(\.worktree), gitPath: repository.runner.gitPath)
        // A switch that happened meanwhile brought its own list; these counters belong to the old one.
        guard infos.map(\.worktree) == worktrees.map(\.worktree) else { return }
        worktrees = infos
        onMetadataChanged?()
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
