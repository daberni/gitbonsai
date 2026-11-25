import Foundation
import GitEngine
import GraphLayout

/// Reading the history, refs, stashes, worktrees and status, in full and as refreshes in place.
extension GraphViewModel {
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
        let path = repository.path
        let load = Signposts.begin("history.load", path)
        let opening = Signposts.begin("repository.open", path)
        // The log waits for HEAD and the stashes. Reading them and starting the log off the main actor lets git and the layout run while the window is still being built.
        let read = repository
        let order = historyOrder
        let prelude = Task.detached { () -> Prelude in
            async let status = try? read.status()
            async let stashes = RefLoader.stashes(of: read)
            let (readStatus, readStashes) = await (status, stashes)
            let log = LogLoader(repository: read, stashesByCommit: readStashes?.byCommit ?? [:], head: readStatus?.branch.headSHA, order: order).start()
            return Prelude(status: readStatus, stashes: readStashes, log: log)
        }
        loadTask = Task { [weak self] in
            let started = await prelude.value
            guard let self else { started.log.producer.cancel(); return }
            defer { load.end(Task.isCancelled ? "cancelled" : "finished") }
            await replaceRemovedWorktree()
            var log: LogLoader.Running?
            if Task.isCancelled {
                started.log.producer.cancel()
                return
            } else if repository.path == read.path {
                status = started.status
                if let readStashes = started.stashes { (stashes, stashesByCommit) = readStashes }
                log = started.log
            } else {
                started.log.producer.cancel()
                status = try? await repository.status()
                await loadStashes()
            }
            layoutHead = headSHA
            async let sidebarTask: Void = loadSidebarContent()
            async let fetchTask: Void = loadLastFetch()
            await streamLog(log, opening: opening)
            _ = await (sidebarTask, fetchTask)
            // A reload that started meanwhile owns the state now.
            if Task.isCancelled { return }
            computeReachability()
            isLoading = false
            readRevision += 1
            onMetadataChanged?()
            publishStatus()
            // Once per tab and after the first load, so it never competes with it; the next load streams from the graph.
            if !hasCheckedCommitGraph {
                hasCheckedCommitGraph = true
                let repository = repository
                Task.detached(priority: .background) { await Signposts.measure("commitGraph.write", repository.path) { await repository.writeCommitGraphIfMissing() } }
            }
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
    /// Everything is read again, the time of the last fetch too, since a fetch in a terminal moves it; only reading the log depends on whether a commit is new.
    func reconcile() async -> Reconciliation {
        if isLoading { return .loading }
        guard inPlaceRefreshes == 0 else { return .refreshing }
        await loadLastFetch()
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
    private func update(focus requested: Focus = .keepSelection) async {
        guard !isLoading else {
            reload(focus: requested == .followHead ? .current : requested)
            return
        }
        let headBefore = headSHA
        let start = ContinuousClock.now
        let interval = Signposts.begin("history.refresh", repository.path)
        defer { interval.end() }
        inPlaceRefreshes += 1
        defer { inPlaceRefreshes -= 1 }
        await replaceRemovedWorktree()
        startedRefreshes += 1
        let ticket = startedRefreshes
        let generation = loadGeneration
        let repository = repository
        let knownWorktrees = worktrees
        // Everything is read into locals and applied together after the ticket check, so a refresh that read the repository earlier never overwrites a later one's state.
        async let statusRead = try? repository.status()
        async let stashesRead = RefLoader.stashes(of: repository)
        async let refsRead = Result { try await RefLoader.refs(of: repository) }
        async let worktreesRead = WorktreeLoader.list(of: repository, keeping: knownWorktrees)
        let (readStatus, readStashes, readRefs, readWorktrees) = await (statusRead, stashesRead, refsRead, worktreesRead)
        // A status that could not be read keeps the last one rather than dropping the working directory row and HEAD's lane.
        let newStatus = readStatus ?? status
        let (newStashes, newStashesByCommit) = readStashes ?? (stashes, stashesByCommit)
        let (newRefs, newRefsByCommit) = (try? readRefs.get()) ?? (refs, refsByCommit)
        var next = history
        next.removeWorkingDirectoryRow()
        var laneCount = maxLaneCount
        let head = newStatus?.branch.headSHA
        // A new commit, stash or a worktree HEAD that no branch contains is not loaded and needs the log.
        let tips = HistoryRefresh.tips(refs: newRefs, head: head, stashCommits: newStashesByCommit.keys)
        // With the same starting points and HEAD, the loaded commits, their layout and what HEAD reaches stay as they are; on a large history the walks cost hundreds of milliseconds.
        let historyMoved = tips != checkedTips || head != layoutHead
        if historyMoved {
            let loaded = next.commits
            switch await Task.detached(operation: { HistoryRefresh.plan(loaded: loaded, tips: tips) }).value {
            case .reload:
                guard let streamed = await readHistory(head: head, stashesByCommit: newStashesByCommit) else { return }
                (next, laneCount) = streamed
            case .keep(let dropping):
                if !dropping.isEmpty {
                    next.remove(dropping)
                    // The rest can move in git's order once commits left it, so git names the order again; without it the whole log is read.
                    if let order = try? await repository.historyOrder(historyOrder, stashCommits: newStashesByCommit.keys.sorted()) {
                        next.reorder(as: order)
                    } else if let streamed = await readHistory(head: head, stashesByCommit: newStashesByCommit) {
                        (next, laneCount) = streamed
                    } else {
                        return
                    }
                }
                // HEAD's strand owns the leftmost lane, so a HEAD on another commit means another layout of the same commits.
                if head != layoutHead || !dropping.isEmpty {
                    let result = await LogLoader.relayout(next.commits, head: head, stashesByCommit: newStashesByCommit)
                    next.replaceRows(result.rows)
                    laneCount = result.maxLaneCount
                }
            }
        }
        insertWipRow(into: &next, status: newStatus)
        // Comparing every row is linear in the history; it runs off the main actor against the rows shown when it started.
        let shownRows = history.rows
        let nextRows = next.rows
        let appliedBefore = appliedRefresh
        var layoutDiff = await Task.detached { HistoryRowDiff.between(shownRows, nextRows) }.value
        // A reload, or a refresh that started later and finished first, owns the history now.
        guard generation == loadGeneration, ticket > appliedRefresh else { return }
        // An earlier refresh applied while the rows were compared: compare against what it showed.
        if appliedRefresh != appliedBefore { layoutDiff = HistoryRowDiff.between(history.rows, nextRows) }
        appliedRefresh = ticket
        status = newStatus
        (stashes, stashesByCommit) = (newStashes, newStashesByCommit)
        (refs, refsByCommit) = (newRefs, newRefsByCommit)
        if let readWorktrees { worktrees = readWorktrees }
        if case .failure(let error) = readRefs {
            setSummary(String(localized: "history.status.refsFailed", defaultValue: "Reading refs failed: \(String(describing: error))", bundle: .module))
        }
        if historyMoved {
            checkedTips = tips
            layoutHead = head
        }
        let shown = history
        history = next
        maxLaneCount = laneCount
        if historyMoved { computeReachability() }
        readRevision += 1
        let focus: Focus = requested == .followHead ? (head == headBefore ? .keepSelection : .current) : requested
        onRowsRebuilt?(rowDiff(layoutDiff, from: shown, to: next), focus)
        onMetadataChanged?()
        setSummary(loadedSummary + " · " + String(localized: "history.status.view", defaultValue: "view \(elapsed(since: start))", bundle: .module, comment: "Status line: how long updating the history view took, e.g. view 3 ms"))
        // The other worktrees' change counters are slow to gather and nothing waits for them.
        Task { await loadWorktreeStatuses() }
    }

    /// Reads the whole log into rows of their own while the table keeps showing the current ones. Nil when the log could not be read to its end.
    private func readHistory(head: String?, stashesByCommit: [String: Stash]) async -> (HistoryRows, Int)? {
        let start = ContinuousClock.now
        let loader = LogLoader(repository: repository, stashesByCommit: stashesByCommit, head: head, order: historyOrder)
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
            setSummary(String(localized: "history.status.logFailed", defaultValue: "git log failed: \(String(describing: error))", bundle: .module))
            return nil
        }
    }

    /// Besides the rows the layout changed, the working directory row shows the new status and stash rows their new position in the stash list.
    private func rowDiff(_ layoutDiff: HistoryRowDiff?, from shown: HistoryRows, to next: HistoryRows) -> HistoryRowDiff? {
        guard var diff = layoutDiff else { return nil }
        let redrawn = (shown.wipRow == nil ? [] : [Self.wipID]) + stashesByCommit.keys
        for id in redrawn {
            guard let row = next.rowIndex(of: id), !diff.inserted.contains(row) else { continue }
            diff.changed.insert(row)
        }
        return diff
    }

    /// What `load` reads off the main actor before the history arrives: status and stashes, and the log already streaming from them.
    struct Prelude: Sendable {
        let status: RepositoryStatus?
        let stashes: (stashes: [Stash], byCommit: [String: Stash])?
        let log: LogLoader.Running
    }

    /// `opening` ends once the first screenful of rows is laid out, or with the load when the history is shorter.
    private func streamLog(_ started: LogLoader.Running?, opening: Signposts.Interval) async {
        let start = ContinuousClock.now
        var opened = false
        defer { if !opened { opening.end("whole history") } }
        let running = started ?? LogLoader(repository: repository, stashesByCommit: stashesByCommit, head: layoutHead, order: historyOrder).start()
        let outcome = await LogLoader.stream(running, onBatch: { batch in
            let range = history.append(batch.commits, rows: batch.rows, kinds: batch.kinds)
            maxLaneCount = batch.maxLaneCount
            onRowsAppended?(range)
            if !opened, history.commitCount >= LogLoader.firstScreenful {
                opened = true
                opening.end("\(LogLoader.firstScreenful) rows")
            }
            // HEAD arrived in this batch: the new first row shifts every row that is already on screen.
            if history.wipRow == nil, insertWipRow(into: &history, status: status) { onRowsShifted?() }
        }, onProgress: {
            setSummary(String(localized: "common.commitCount", defaultValue: "\(commits.count) commits", bundle: .module) + " · " + elapsed(since: start))
        })
        // Without any commit no batch arrived to put the working directory row on.
        if history.wipRow == nil, outcome.isFinished, insertWipRow(into: &history, status: status) { onRowsShifted?() }
        switch outcome {
        case .finished:
            loadDuration = elapsed(since: start)
            setSummary(loadedSummary)
        case .cancelled:
            break
        case .failed(let error):
            setSummary(String(localized: "history.status.logFailed", defaultValue: "git log failed: \(String(describing: error))", bundle: .module))
        }
    }

    /// Uncommitted changes always show as the first row, also on a branch that has no commit yet.
    @discardableResult
    private func insertWipRow(into rows: inout HistoryRows, status: RepositoryStatus?) -> Bool {
        guard let status, !status.entries.isEmpty else { return false }
        return rows.insertWorkingDirectoryRow(head: status.branch.headSHA)
    }

    private func computeReachability() {
        guard let head = headSHA else { return }
        reachableFromHead = history.reachable(from: head)
    }

    private func loadRefs() async {
        do {
            (refs, refsByCommit) = try await RefLoader.refs(of: repository)
            onMetadataChanged?()
        } catch {
            setSummary(String(localized: "history.status.refsFailed", defaultValue: "Reading refs failed: \(String(describing: error))", bundle: .module))
        }
    }

    private func loadStashes() async {
        guard let loaded = await RefLoader.stashes(of: repository) else { return }
        (stashes, stashesByCommit) = loaded
    }

    func loadLastFetch() async {
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
        onMetadataChanged?()
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

    func setNote(_ note: String?) {
        statusLine.note = note
        publishStatus()
    }

    private func publishStatus() {
        onStatusChanged?(statusLine.text)
    }

    func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: .now)
        let milliseconds = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        let measurement = milliseconds < 1000 ? Measurement(value: milliseconds.rounded(), unit: UnitDuration.milliseconds) : Measurement(value: milliseconds / 1000, unit: UnitDuration.seconds)
        let digits = milliseconds < 1000 ? 0 : 2
        return measurement.formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(digits)).locale(AppLanguage.locale)).locale(AppLanguage.locale))
    }
}
