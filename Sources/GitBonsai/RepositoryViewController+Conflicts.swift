import AppKit
import GitEngine

/// A conflicted file of the working directory opens the conflict view in the history pane instead of a diff; resolving it moves on to the next one.
extension RepositoryViewController {
    // MARK: Conflicts

    /// Whether a file chosen in the detail panel is one of the working directory's unresolved conflicts.
    func isConflict(_ selection: FileSelection) -> Bool {
        selection.source == .unstaged && viewModel.status?.conflicted.contains { $0.path == selection.path } == true
    }

    func showConflict(_ path: String) {
        diff.close()
        stackedDiff.close()
        conflicts.show(path: path) { [weak self] in
            guard let self else { return }
            historyPane.show(conflicts.view)
            conflicts.scrollToTop()
        }
    }

    /// The ours and theirs names for the operation that stopped.
    func conflictSides() -> ConflictSides {
        ConflictSides.of(operationBanner.progress, branch: viewModel.status?.branch.branch, head: viewModel.headSHA) { [operationBanner] sha in operationBanner.name(of: sha).marked }
    }

    /// The next unresolved file opens; with none left the graph comes back, where the banner offers Continue.
    func conflictResolved(_ path: String) {
        let remaining = viewModel.status?.conflicted.map(\.path).filter { $0 != path } ?? []
        guard let next = remaining.first else {
            conflicts.close()
            historyPane.show(history.view)
            detail.selectedFiles = []
            view.window?.makeFirstResponder(history.tableView)
            return
        }
        let selection = FileSelection(path: next, originalPath: nil, source: .unstaged)
        detail.selectedFiles = [selection]
        showConflict(next)
    }

    func wireConflicts() {
        conflicts.onClose = { [weak self] in self?.showGraph() }
        conflicts.onResolved = { [weak self] path in self?.conflictResolved(path) }
    }
}
