import AppKit
import GitEngine

/// How the history selection reaches the detail panel, the diff and the commit form.
extension RepositoryViewController {
    // MARK: Diff

    /// Opens a file as if it was chosen in the detail panel.
    func openFile(_ selection: FileSelection) {
        detail.selectedFile = selection
        showDiff(selection)
    }

    func showDiff(_ selection: FileSelection) {
        if isConflict(selection) { return showConflict(selection.path) }
        conflicts.close()
        diff.show(selection) { [weak self] in
            guard let self else { return }
            historyPane.show(diff.view)
        }
    }

    /// The diff's close button or Escape: the graph comes back with the focus.
    func showGraph() {
        diff.close()
        conflicts.close()
        historyPane.show(history.view)
        detail.selectedFile = nil
        view.window?.makeFirstResponder(history.tableView)
    }

    /// Navigation closes an open diff. The focus goes to the history when it was in the diff or in the file list that opened it, which the new selection replaces;
    /// elsewhere, such as in the search field, it stays, so typing goes on.
    private func closeDiff() {
        diff.close()
        conflicts.close()
        let open = historyPane.current
        guard open === diff.view || open === conflicts.view, let open else { return }
        let focus = view.window?.firstResponder as? NSView
        let focusFollows = focus.map { $0.isDescendant(of: open) || $0.isDescendant(of: detail) } ?? true
        historyPane.show(history.view)
        if focusFollows { view.window?.makeFirstResponder(history.tableView) }
    }

    /// Selects the stash in the history, so the detail panel lists its files, and opens the first one's diff, unless the selection moved on while its files were read.
    func showStash(_ stash: Stash) {
        history.navigate(to: stash.commitID)
        guard let row = viewModel.rowIndex(of: stash.commitID) else { return }
        let commit = viewModel.commits[row]
        Task {
            guard let file = try? await viewModel.repository.changedFiles(of: commit).first, shownSelection == [commit.id] else { return }
            openFile(FileSelection(path: file.path, originalPath: file.originalPath, source: .commit(commit)))
        }
    }

    /// Selects the working directory row, where conflicts left by a stash show.
    func showWorkingDirectory() {
        guard let row = viewModel.kinds.firstIndex(of: .wip) else { return }
        history.select(row: row, scroll: true)
    }

    /// A rebase, cherry-pick, revert or merge is over: the history shows HEAD, and no file or diff of the conflict state stays open.
    /// A rewrite reads the log again, so HEAD may not be a row yet; the selection then waits for the reload.
    func operationEnded() {
        // The operation moved HEAD on purpose; even an unchanged selection now shows another state.
        shownSelection = nil
        selectionChanged(to: history.selectedRows)
        selectsHeadAfterLoad = true
        selectHeadIfLoaded()
    }

    func selectHeadIfLoaded() {
        guard selectsHeadAfterLoad, !viewModel.isLoading, let row = viewModel.headSHA.flatMap({ viewModel.rowIndex(of: $0) }) else { return }
        selectsHeadAfterLoad = false
        history.select(row: row, scroll: true)
    }

    func showsCommitForm(at row: Int?) -> Bool {
        guard let row, viewModel.kinds.indices.contains(row) else { return false }
        let isHead = viewModel.commits[row].id == viewModel.headSHA
        // Amending with nothing changed shows the form under HEAD, as at an edit stop.
        return viewModel.kinds[row] == .wip || isHead && (operationBanner.isEditStop || commitController.form.isAmend)
    }

    /// The one rule for every way the history selection moves: a click or arrow key, ⌘- or ⇧-click, the parent link, the sidebar, tags and stashes, the search,
    /// a checkout or worktree switch, a commit that left the history, the end of a rebase. Another set of selected commits than the one shown closes an open diff and shows the new selection.
    /// The same commits again, as after staging, leave diff and panel as they are; changes of the working directory reach the panel through `metadataChanged`.
    /// The table clears its selection for a moment while it is rebuilt; that is no change either.
    func selectionChanged(to rows: IndexSet) {
        guard !rows.isEmpty, let last = rows.last, last < viewModel.commits.count else { return }
        let ids = rows.map { viewModel.commits[$0].id }
        guard ids != shownSelection else { return }
        shownSelection = ids
        closeDiff()
        comparison?.cancel()
        comparison = nil
        if rows.count == 1 {
            showDetail(for: last)
        } else {
            showComparison(of: rows)
        }
    }

    /// The selected row while exactly one is selected.
    var singleSelectedRow: Int? {
        history.selectedRows.count == 1 ? history.selectedRows.first : nil
    }

    /// The base switch replaces the files; an open diff moves to the same file in the new comparison, or closes when it is not part of it.
    func showComparison(of rows: IndexSet) {
        detail.selectedFile = nil
        rightColumn.showsBar = false
        let panel = detail.showComparison(of: rows.map { viewModel.commits[$0] }, repository: viewModel.repository)
        panel.onFilesReplaced = { [weak self] models in
            guard let self, let open = detail.selectedFile else { return }
            if let match = models.first(where: { $0.selection.path == open.path })?.selection {
                detail.selectedFile = match
                showDiff(match)
            } else {
                detail.selectedFile = nil
                closeDiff()
            }
        }
        comparison = panel
    }

    /// A new selection in the history starts without a chosen file; a redraw of the same one keeps it.
    func showDetail(for row: Int?, keepingFile: Bool = false) {
        if !keepingFile { detail.selectedFile = nil }
        rightColumn.showsBar = showsCommitForm(at: row)
        guard let row else { detail.showNothing(); return }
        if viewModel.kinds[row] == .wip, let status = viewModel.status {
            shownStatus = status
            detail.showWorkingDirectory(status: status, repository: viewModel.repository)
        } else {
            detail.show(commit: viewModel.commits[row], strand: Theme.strand(viewModel.rows[row].color), repository: viewModel.repository)
        }
    }
}
