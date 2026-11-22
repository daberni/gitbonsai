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
        /// The action brought changes back onto HEAD, such as a pop: HEAD is selected and brought into view, even with uncommitted changes on top.
        case head
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
    private var statusLine = StatusLine(summary: String(localized: "Loading…", bundle: .module))
    var statusText: String { statusLine.text }
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
    /// A refresh swapped in new rows at once: the difference to the rows shown before, nil when rows that stayed changed their order.
    var onRowsRebuilt: ((HistoryRowDiff?, Focus) -> Void)?

    /// Rebound when the tab moves to another worktree of the same repository.
    private(set) var repository: Repository
    /// The commit the current layout keeps the leftmost lane for.
    private var layoutHead: String?
    private var loadTask: Task<Void, Never>?
    /// While a refresh gathers its parts, the single redraw at its end replaces the per-part ones.
    private var isRefreshing = false
    private var loadDuration = ""
    /// Counted live, because a refresh can drop commits and lay them out again.
    private var loadedSummary: String { [String(localized: "\(history.commitCount) commits", bundle: .module), String(localized: "\(maxLaneCount) lanes", bundle: .module, comment: "Status line: lanes of the commit graph"), String(localized: "\(stashes.count) stashes", bundle: .module), String(localized: "loaded in \(loadDuration)", bundle: .module, comment: "Status line: how long reading the history took, e.g. 26 ms")].joined(separator: " · ") }
    private var reachableFromHead: Set<String> = []
    private var sidebarChanges = 0
    private var hasSidebarContent = false
    private var inPlaceRefreshes = 0
    /// Counts the in-place refreshes started and the newest one applied, so that one which read the repository earlier never replaces the rows of a later one.
    private var startedRefreshes = 0
    private var appliedRefresh = 0
    /// Counts full reloads; a refresh that began before one drops its rows.
    private var loadGeneration = 0
    /// The history starting points the loaded commits were last checked against; nil until a refresh checked them after a load.
    private var checkedTips: Set<String>?

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
        setNote(String(localized: "Switching…", bundle: .module, comment: "Status line while checking out"))
        let start = ContinuousClock.now
        do {
            try await repository.checkout(target, stashMessage: target.stashMessage)
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
            setNote(nil)
            return .failed("\(error)")
        }
    }

    /// Shows another worktree of the same repository in place.
    func switchWorktree(to path: String) {
        repository = Repository(path: path, gitPath: repository.runner.gitPath)
        Task { await refresh(note: nil, focus: .current) }
    }

    /// Runs one fetch variant; the status line names the command and its duration. Returns git's error so the caller can show its message.
    /// New remote commits only enter the history through the log, so the fetch ends with an in-place refresh, which reads it when a ref points at a commit that is not loaded. A failed fetch may still have moved some refs.
    func fetch(_ variant: FetchVariant) async -> Error? {
        setNote("\(variant.commandLine) …")
        isFetching = true
        defer { isFetching = false }
        let start = ContinuousClock.now
        do {
            try await repository.fetch(variant)
            await loadLastFetch()
            await refresh(note: "\(variant.commandLine) \(elapsed(since: start))")
            return nil
        } catch {
            await loadLastFetch()
            let message = (error as? GitError)?.stderr.split(separator: "\n").first.map(String.init) ?? "\(error)"
            await refresh(note: String(localized: "\(variant.commandLine) failed after \(elapsed(since: start)): \(message)", bundle: .module, comment: "Status line: git command, duration, git's error"))
            return error
        }
    }

    // MARK: Loading

    /// Drops everything that was loaded and reads the repository again.
    func reload(focus: Focus = .keepSelection) {
        loadTask?.cancel()
        loadGeneration += 1
        history = HistoryRows()
        checkedTips = nil
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
            publishStatus()
        }
    }

    enum Reconciliation {
        /// The first load or a reload is under way and reads everything anyway.
        case loading
        /// Another in-place refresh is under way; it may have read the repository before the change that asked for this one.
        case refreshing
        case done
    }

    /// Brings the tab in line with the repository after changes made outside the app, in a terminal, an editor or another worktree. Local only: it never fetches.
    /// Everything is read again; only reading the log depends on whether a commit is new.
    func reconcile() async -> Reconciliation {
        if isLoading { return .loading }
        guard inPlaceRefreshes == 0 else { return .refreshing }
        await update()
        return .done
    }

    /// Brings the tab up to date after an action; `note` replaces the previous action's note, nil clears it.
    func refresh(note: String?, focus: Focus = .keepSelection) async {
        setNote(note)
        await update(focus: focus)
    }

    /// After a checkout, a reset or a worktree switch the commits are mostly the same: HEAD, the working directory and the refs moved.
    /// So nothing is read from the log as long as every tip is loaded: commits no tip reaches anymore leave, and the rest are laid out again when HEAD or the commits changed. A new tip, such as a new commit or stash, reads the whole log into rows of their own.
    /// The new rows replace the shown ones in one step at the end, and the table hears only the difference, so it never shows an empty or half-built history.
    /// The history keeps its selection unless `focus` asks for another row. The status line's note stays as it is.
    private func update(focus: Focus = .keepSelection) async {
        guard !isLoading else {
            reload(focus: focus)
            return
        }
        let start = ContinuousClock.now
        inPlaceRefreshes += 1
        defer { inPlaceRefreshes -= 1 }
        startedRefreshes += 1
        let ticket = startedRefreshes
        let generation = loadGeneration
        isRefreshing = true
        async let newStatus = try? repository.status()
        async let stashesTask: Void = loadStashes()
        async let refsTask: Void = loadRefs()
        async let worktreesTask: Void = loadWorktreeList()
        status = await newStatus
        _ = await (stashesTask, refsTask, worktreesTask)
        isRefreshing = false
        var next = history
        next.removeWorkingDirectoryRow()
        var laneCount = maxLaneCount
        let head = headSHA
        // A new commit, stash or a worktree HEAD that no branch contains is not loaded and needs the log.
        let tips = HistoryRefresh.tips(refs: refs, head: head, stashCommits: stashesByCommit.keys)
        // With the same starting points and HEAD, the loaded commits, their layout and what HEAD reaches stay as they are; on a large history the walks cost hundreds of milliseconds.
        let historyMoved = tips != checkedTips || head != layoutHead
        if historyMoved {
            let loaded = next.commits
            switch await Task.detached(operation: { HistoryRefresh.plan(loaded: loaded, tips: tips) }).value {
            case .reload:
                guard let streamed = await readHistory(head: head) else { return }
                (next, laneCount) = streamed
            case .keep(let dropping):
                if !dropping.isEmpty {
                    next.remove(dropping)
                    // The rest can move in git's topological order once commits left it, so git names the order again; without it the whole log is read.
                    if let order = try? await repository.historyOrder(stashCommits: stashesByCommit.keys.sorted()) {
                        next.reorder(as: order)
                    } else if let streamed = await readHistory(head: head) {
                        (next, laneCount) = streamed
                    } else {
                        return
                    }
                }
                // HEAD's strand owns the leftmost lane, so a HEAD on another commit means another layout of the same commits.
                if head != layoutHead || !dropping.isEmpty {
                    let result = await LogLoader.relayout(next.commits, head: head, stashesByCommit: stashesByCommit)
                    next.replaceRows(result.rows)
                    laneCount = result.maxLaneCount
                }
            }
        }
        // A reload, or a refresh that started later and finished first, owns the history now.
        guard generation == loadGeneration, ticket > appliedRefresh else { return }
        appliedRefresh = ticket
        if historyMoved {
            checkedTips = tips
            layoutHead = head
        }
        insertWipRow(into: &next)
        let shown = history
        history = next
        maxLaneCount = laneCount
        if historyMoved { computeReachability() }
        onRowsRebuilt?(rowDiff(from: shown, to: next), focus)
        onMetadataChanged?()
        setSummary(loadedSummary + " · " + String(localized: "view \(elapsed(since: start))", bundle: .module, comment: "Status line: how long updating the history view took, e.g. view 3 ms"))
        // The other worktrees' change counters are slow to gather and nothing waits for them.
        Task { await loadWorktreeStatuses() }
    }

    /// Reads the whole log into rows of their own while the table keeps showing the current ones. Nil when the log could not be read to its end.
    private func readHistory(head: String?) async -> (HistoryRows, Int)? {
        let start = ContinuousClock.now
        let loader = LogLoader(repository: repository, stashesByCommit: stashesByCommit, head: head)
        var read = HistoryRows()
        var laneCount = 1
        let outcome = await loader.stream(onBatch: { batch in
            _ = read.append(batch.commits, rows: batch.rows, kinds: batch.kinds)
            laneCount = batch.maxLaneCount
        }, onProgress: {})
        switch outcome {
        case .finished:
            loadDuration = elapsed(since: start)
            return (read, laneCount)
        case .cancelled:
            return nil
        case .failed(let error):
            setSummary(String(localized: "git log failed: \(String(describing: error))", bundle: .module))
            return nil
        }
    }

    /// Besides the rows the layout changed, the working directory row shows the new status and stash rows their new position in the stash list.
    private func rowDiff(from shown: HistoryRows, to next: HistoryRows) -> HistoryRowDiff? {
        guard var diff = HistoryRowDiff.between(shown.rows, next.rows) else { return nil }
        let redrawn = (shown.wipRow == nil ? [] : [Self.wipID]) + stashesByCommit.keys
        for id in redrawn {
            guard let row = next.rowIndex(of: id), !diff.inserted.contains(row) else { continue }
            diff.changed.insert(row)
        }
        return diff
    }

    private func streamLog() async {
        let start = ContinuousClock.now
        let loader = LogLoader(repository: repository, stashesByCommit: stashesByCommit, head: layoutHead)
        let outcome = await loader.stream(onBatch: { batch in
            let range = history.append(batch.commits, rows: batch.rows, kinds: batch.kinds)
            maxLaneCount = batch.maxLaneCount
            onRowsAppended?(range)
            if history.wipRow == nil {
                insertWipRow(into: &history)
                // HEAD arrived in this batch: the new first row shifts every row that is already on screen.
                if history.wipRow != nil { onRowsShifted?() }
            }
        }, onProgress: {
            setSummary(String(localized: "\(commits.count) commits", bundle: .module) + " · " + elapsed(since: start))
        })
        switch outcome {
        case .finished:
            loadDuration = elapsed(since: start)
            setSummary(loadedSummary)
        case .cancelled:
            break
        case .failed(let error):
            setSummary(String(localized: "git log failed: \(String(describing: error))", bundle: .module))
        }
    }

    /// Uncommitted changes always show as the first row.
    private func insertWipRow(into rows: inout HistoryRows) {
        guard !(status?.entries.isEmpty ?? true), let head = headSHA else { return }
        rows.insertWorkingDirectoryRow(head: head)
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
            setSummary(String(localized: "Reading refs failed: \(String(describing: error))", bundle: .module))
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

    private func setSummary(_ summary: String) {
        statusLine.summary = summary
        publishStatus()
    }

    private func setNote(_ note: String?) {
        statusLine.note = note
        publishStatus()
    }

    private func publishStatus() {
        onStatusChanged?(statusLine.text)
    }

    private func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        let measurement = milliseconds < 1000 ? Measurement(value: milliseconds.rounded(), unit: UnitDuration.milliseconds) : Measurement(value: milliseconds / 1000, unit: UnitDuration.seconds)
        let digits = milliseconds < 1000 ? 0 : 2
        return measurement.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(digits)).locale(AppLanguage.locale)).locale(AppLanguage.locale))
    }
}
