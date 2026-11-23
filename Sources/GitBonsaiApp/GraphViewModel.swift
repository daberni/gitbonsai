import Foundation
import GitEngine
import GraphLayout

/// Owns everything one repository window shows: the streamed commit list with its layout, refs, stashes, worktrees and the working directory status.
///
/// It coordinates the parts: `LogLoader` streams the history into `HistoryRows`, `RefLoader` and `WorktreeLoader` read the rest.
@MainActor
final class GraphViewModel {
    enum RowKind: Sendable { case commit, merge, stash, wip }

    /// Which row the history shows once a refresh rebuilt its rows.
    enum Focus {
        /// The selected commit stays selected at the same place on screen, as long as it is still in the history.
        case keepSelection
        /// The action moved the working tree on purpose, such as a checkout: the uncommitted changes or HEAD are selected and HEAD is brought into view.
        case current
        /// The action brought changes back onto HEAD, such as a pop: HEAD is selected and brought into view, even with uncommitted changes on top.
        case head
        /// The action may have moved HEAD, such as a reset, pull, rebase or undo: `current` when HEAD is on another commit afterwards, else `keepSelection`.
        case followHead
    }

    static let wipID = HistoryRows.wipID

    var history = HistoryRows()
    var commits: [Commit] { history.commits }
    var rows: [GraphRow] { history.rows }
    var kinds: [RowKind] { history.kinds }
    // Only real changes count, so a reconcile that read the same state leaves the sidebar alone.
    var refs: [Ref] = [] { didSet { if refs != oldValue { sidebarChanges += 1 } } }
    var refsByCommit: [String: [Ref]] = [:]
    var stashes: [Stash] = [] { didSet { if stashes != oldValue { sidebarChanges += 1 } } }
    var stashesByCommit: [String: Stash] = [:]
    var worktrees: [WorktreeInfo] = [] {
        didSet {
            guard worktrees != oldValue else { return }
            sidebarChanges += 1
            updateBranchesInOtherWorktrees()
        }
    }
    var status: RepositoryStatus? { didSet { if status != oldValue { sidebarChanges += 1 } } }
    /// The folder of the repository's main worktree, whichever worktree the tab shows.
    let repositoryName: String
    var lastFetch: Date?
    /// The last local operation the status line's Undo can take back.
    var undoOffer: UndoOffer?
    private(set) var isFetching = false {
        didSet { if isFetching != oldValue { onFetchActivityChanged?() } }
    }
    /// git's first line from the last fetch while it failed; nil once a fetch succeeded.
    private(set) var lastFetchFailure: String?
    /// A fetch started or ended, also one started by the auto fetch.
    var onFetchActivityChanged: (() -> Void)?
    /// The fetch, pull or push running in this tab.
    let remoteActivity = RemoteActivity()
    var statusLine = StatusLine(summary: String(localized: "history.status.loading", defaultValue: "Loading…", bundle: .module))
    var statusText: String { statusLine.text }
    var isLoading = false
    var maxLaneCount = 1

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
    var layoutHead: String?
    var loadTask: Task<Void, Never>?
    var loadDuration = ""
    /// Counted live, because a refresh can drop commits and lay them out again.
    var loadedSummary: String { [String(localized: "common.commitCount", defaultValue: "\(history.commitCount) commits", bundle: .module), String(localized: "history.status.lanes", defaultValue: "\(maxLaneCount) lanes", bundle: .module, comment: "Status line: lanes of the commit graph"), String(localized: "history.status.stashes", defaultValue: "\(stashes.count) stashes", bundle: .module), String(localized: "history.status.loadedIn", defaultValue: "loaded in \(loadDuration)", bundle: .module, comment: "Status line: how long reading the history took, e.g. 26 ms")].joined(separator: " · ") }
    var reachableFromHead: Set<String> = []
    private var sidebarChanges = 0
    /// Counts the loads and refreshes that read the whole repository; what depends on more than the view model's state, such as remotes, upstream or a running operation, is read again only when it changes.
    var readRevision = 0
    var hasSidebarContent = false
    var inPlaceRefreshes = 0
    /// Counts the in-place refreshes started and the newest one applied, so that one which read the repository earlier never replaces the rows of a later one.
    var startedRefreshes = 0
    var appliedRefresh = 0
    /// Counts full reloads; a refresh that began before one drops its rows.
    var loadGeneration = 0
    /// The history starting points the loaded commits were last checked against; nil until a refresh checked them after a load.
    var checkedTips: Set<String>?
    /// Whether this tab already asked git to write a missing commit-graph file.
    var hasCheckedCommitGraph = false

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

    /// Full ref names of branches checked out in a worktree other than this window's. Kept, since every history row asks while it draws and resolving paths costs file system calls.
    private(set) var branchesInOtherWorktrees: [String: Worktree] = [:]

    private func updateBranchesInOtherWorktrees() {
        var result: [String: Worktree] = [:]
        for info in worktrees {
            guard let branch = info.worktree.branch, !isCurrent(info.worktree) else { continue }
            result[branch] = info.worktree
        }
        branchesInOtherWorktrees = result
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

    /// The tab closed: a log still streaming and a refresh under way stop.
    func close() {
        loadTask?.cancel()
        loadGeneration += 1
    }

    // MARK: Actions

    func checkout(_ target: CheckoutTarget) async -> CheckoutOutcome {
        setNote(String(localized: "history.status.switching", defaultValue: "Switching…", bundle: .module, comment: "Status line while checking out"))
        let start = ContinuousClock.now
        do {
            let repository = repository
            try await recordingUndo(target.undoScope, operation: "git switch") { try await repository.checkout(target, stashMessage: target.stashMessage) }
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
        updateBranchesInOtherWorktrees()
        Task { await refresh(note: nil, focus: .current) }
    }

    /// Runs one fetch variant; the status line names the command and its duration. Returns git's error so the caller can show its message.
    /// New remote commits only enter the history through the log, so the fetch ends with an in-place refresh, which reads it when a ref points at a commit that is not loaded. A failed fetch may still have moved some refs.
    /// A `background` fetch, such as the automatic one, only shows in the fetch state, not on the Fetch button. A cancelled fetch is no failure and returns nil.
    func fetch(_ variant: FetchVariant, background: Bool = false) async -> Error? {
        await remoteActivity.run(.fetch, background: background) { [self] in await performFetch(variant) }
    }

    private func performFetch(_ variant: FetchVariant) async -> Error? {
        setNote("\(variant.commandLine) …")
        isFetching = true
        defer { isFetching = false }
        let start = ContinuousClock.now
        do {
            try await repository.fetch(variant)
            lastFetchFailure = nil
            await loadLastFetch()
            await refresh(note: "\(variant.commandLine) \(elapsed(since: start))")
            return nil
        } catch is CancellationError {
            await refreshAfterCancel(variant.commandLine)
            return nil
        } catch {
            await loadLastFetch()
            let message = (error as? GitError)?.stderr.split(separator: "\n").first.map(String.init) ?? "\(error)"
            lastFetchFailure = message
            await refresh(note: String(localized: "history.status.failedAfter", defaultValue: "\(variant.commandLine) failed after \(elapsed(since: start)): \(message)", bundle: .module, comment: "Status line: git command, duration, git's error"))
            return error
        }
    }

    /// Refreshes after the user cancelled a remote operation, which may have moved refs already. The refresh runs outside the cancelled task, whose git calls would stop at once.
    func refreshAfterCancel(_ commandLine: String, focus: Focus = .keepSelection) async {
        let note = String(localized: "history.status.cancelled", defaultValue: "\(commandLine) cancelled", bundle: .module, comment: "Status line: git command the user cancelled")
        await Task { @MainActor in await refresh(note: note, focus: focus) }.value
    }
}
