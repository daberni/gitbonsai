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
        setSummary(loadedSummary + " · " + String(localized: "history.status.view", defaultValue: "view \(elapsed(since: start))", bundle: .module, comment: "Status line: how long updating the history view took, e.g. view 3 ms"))
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
            setSummary(String(localized: "history.status.logFailed", defaultValue: "git log failed: \(String(describing: error))", bundle: .module))
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
            setSummary(String(localized: "common.commitCount", defaultValue: "\(commits.count) commits", bundle: .module) + " · " + elapsed(since: start))
        })
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
