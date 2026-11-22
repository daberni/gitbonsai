import Foundation
import GitEngine

/// The commit search of one history: the query, which loaded commits match it, and stepping from match to match.
///
/// Matching runs off the main thread in chunks, so typing stays fluid and matches show up while a large history is still streaming in.
@MainActor
final class HistorySearchController {
    /// Matches or the query changed: visible rows and the counter need a redraw.
    var onChange: (() -> Void)?
    /// A new query found the row to select, see `CommitSearchJump`.
    var onJump: ((Int) -> Void)?
    /// The selected row, read when a query takes effect.
    var selectedRow: () -> Int = { -1 }

    private(set) var search: CommitSearch?
    private let viewModel: GraphViewModel
    /// Matching commits in history order, and the same as a set for the per-row lookup while drawing.
    private var orderedMatches: [String] = []
    private var matchSet: Set<String> = []
    /// Commits before this position in `viewModel.commits` have been matched against the current query.
    private var scannedUpTo = 0
    /// A rescan keeps the old matches on screen until its first chunk replaces them, so typing does not blank the history.
    private var replaceOnNextChunk = false
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var scannedRefs: [Ref] = []
    /// Set by a typed query only; rescans after history changes leave the selection alone.
    private var jump: CommitSearchJump?

    /// Commits per background pass; the shown matches grow after each one.
    private static let chunkSize = 20_000
    private static let debounce: Duration = .milliseconds(90)

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
    }

    /// Whether a row stays at full strength: always without a search, otherwise only for a match.
    func isMatch(row: Int) -> Bool {
        guard search != nil, row < viewModel.commits.count else { return true }
        return matchSet.contains(viewModel.commits[row].id)
    }

    /// Typing restarts matching after a short pause; clearing the field ends the search at once.
    func setQuery(_ text: String) {
        debounceTask?.cancel()
        guard let next = CommitSearch(text) else {
            clear()
            return
        }
        guard next != search else { return }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            jump = CommitSearchJump(search: next, refines: search != nil, selected: selectedCommit(), refNames: selectedRefNames())
            search = next
            rescan()
        }
    }

    func clear() {
        debounceTask?.cancel()
        scanTask?.cancel()
        scanTask = nil
        let wasActive = search != nil
        search = nil
        jump = nil
        orderedMatches = []
        matchSet = []
        replaceOnNextChunk = false
        scannedUpTo = 0
        if wasActive { onChange?() }
    }

    // MARK: History changes

    /// New commits at the end of the history only need the new part matched.
    func commitsAppended() {
        guard search != nil else { return }
        continueScan()
    }

    /// Rows moved, were rebuilt or dropped: positions are stale, so everything is matched again.
    func historyChanged() {
        guard search != nil else { return }
        rescan()
    }

    /// Ref names are part of what matches, so new or moved refs mean another pass.
    func refsMayHaveChanged() {
        guard search != nil, viewModel.refs != scannedRefs else { return }
        rescan()
    }

    private func rescan() {
        scanTask?.cancel()
        scanTask = nil
        scannedUpTo = 0
        replaceOnNextChunk = true
        continueScan()
    }

    /// Matches the next chunk in the background and chains itself until every loaded commit is matched.
    private func continueScan() {
        guard scanTask == nil, let search else { return }
        let commits = viewModel.commits
        guard scannedUpTo < commits.count else {
            // An empty history still has to drop the old matches.
            if replaceOnNextChunk { accept([], scannedTo: scannedUpTo) }
            return
        }
        let range = scannedUpTo..<min(scannedUpTo + Self.chunkSize, commits.count)
        if scannedUpTo == 0 { scannedRefs = viewModel.refs }
        let refNames = viewModel.refsByCommit.mapValues { $0.map(\.name) }
        let wipID = GraphViewModel.wipID
        scanTask = Task { [weak self] in
            let ids = await Task.detached(priority: .userInitiated) {
                search.matchingIndices(in: commits, range: range, refNames: refNames).map { commits[$0].id }.filter { $0 != wipID }
            }.value
            guard !Task.isCancelled, let self, self.search == search else { return }
            scanTask = nil
            accept(ids, scannedTo: range.upperBound)
            continueScan()
        }
    }

    private func accept(_ ids: [String], scannedTo end: Int) {
        scannedUpTo = end
        if replaceOnNextChunk {
            replaceOnNextChunk = false
            orderedMatches = ids
            matchSet = Set(ids)
        } else {
            orderedMatches.append(contentsOf: ids)
            matchSet.formUnion(ids)
        }
        if let id = jump?.target(among: ids), let row = viewModel.rowIndex(of: id) { onJump?(row) }
        onChange?()
    }

    /// A row the user picked, by click, keys or stepping, is kept even if the query's first match is still to come.
    func userSelected() {
        jump?.cancel()
    }

    /// Nil for no selection and for the uncommitted changes, which never match.
    private func selectedCommit() -> Commit? {
        let row = selectedRow()
        guard viewModel.commits.indices.contains(row), viewModel.kinds[row] != .wip else { return nil }
        return viewModel.commits[row]
    }

    private func selectedRefNames() -> [String] {
        guard let id = selectedCommit()?.id else { return [] }
        return viewModel.refsByCommit[id]?.map(\.name) ?? []
    }

    // MARK: Stepping

    /// The next match after `row` (or the previous one before it), wrapping around; nil without matches.
    func step(from row: Int, forward: Bool) -> Int? {
        guard !orderedMatches.isEmpty else { return nil }
        let index = forward ? position(ofRow: row + 1) : position(ofRow: row) - 1
        let wrapped = (index + orderedMatches.count) % orderedMatches.count
        return viewModel.rowIndex(of: orderedMatches[wrapped])
    }

    /// "3 of 42" while a match is selected, otherwise the number of matches; "No matches" for none. Nil without a search.
    func counter(selectedRow: Int) -> String? {
        guard search != nil else { return nil }
        if orderedMatches.isEmpty || replaceOnNextChunk { return scanTask == nil && !replaceOnNextChunk ? String(localized: "history.search.noMatches", defaultValue: "No matches", bundle: .module) : "…" }
        let total = orderedMatches.count
        guard selectedRow >= 0, selectedRow < viewModel.commits.count, matchSet.contains(viewModel.commits[selectedRow].id) else { return String(localized: "history.search.matches", defaultValue: "\(total) matches", bundle: .module) }
        let position = position(ofRow: selectedRow)
        return String(localized: "history.search.position", defaultValue: "\(position + 1) of \(total)", bundle: .module, comment: "Search counter: the selected match of all matches")
    }

    /// Matches are in history order and so are their rows, so the selected match is found by bisection.
    private func position(ofRow row: Int) -> Int {
        var low = 0
        var high = orderedMatches.count
        while low < high {
            let mid = (low + high) / 2
            if (viewModel.rowIndex(of: orderedMatches[mid]) ?? Int.max) < row { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
