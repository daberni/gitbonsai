import AppKit
import GitEngine

/// Connects the tab's parts and controllers to each other.
extension RepositoryViewController {
    // MARK: Wiring

    func wire() {
        toolbar.onFetch = { [weak self] in self?.fetchUseCase.fetch(.allRemotes) }
        toolbar.fetchMenu = { [weak self] in MenuAdapter.menu(self?.menuBuilder.toolbarMenu(.fetch) ?? []) }
        fetchUseCase.onRemotesChanged = { [weak self] in
            guard let self else { return }
            showFetchState()
            sidebar.remotes = fetchUseCase.remotes
            sidebar.reload(from: viewModel)
        }
        toolbar.pullMenu = { [weak self] in MenuAdapter.menu(self?.menuBuilder.toolbarMenu(.pull) ?? []) }
        toolbar.pushMenu = { [weak self] in MenuAdapter.menu(self?.menuBuilder.toolbarMenu(.push) ?? []) }
        upstreamStatus.onChange = { [weak self] in
            guard let self else { return }
            toolbar.showUpstream(pullBlocked: upstreamStatus.pullBlocked, pushBlocked: upstreamStatus.pushBlocked, upstream: upstreamStatus.upstream, lacksUpstream: upstreamStatus.lacksUpstream)
            showFetchState()
        }
        viewModel.onFetchActivityChanged = { [weak self] in self?.showFetchState() }
        viewModel.remoteActivity.onChange = { [weak self] in
            guard let self else { return }
            toolbar.showRemoteActivity(viewModel.remoteActivity.running)
        }
        toolbar.onCancelRemote = { [weak self] in self?.viewModel.remoteActivity.cancel() }
        history.connect(searchField: toolbar.searchField)

        sidebar.onSelectCommit = { [weak self] sha in self?.history.navigate(to: sha) }
        sidebar.onCheckout = { [weak self] target, worktreePath in self?.checkoutUseCase.perform(target, worktreePath: worktreePath) }
        sidebar.onSwitchWorktree = { [weak self] path in self?.onSwitchWorktree?(path) }
        sidebar.onOpenPanel = { [weak self] panel, anchor in
            guard let self else { return }
            switch panel {
            case .tags: tagActions.show(relativeTo: anchor, of: sidebar.outlineView)
            case .stashes: stashActions.show(relativeTo: anchor, of: sidebar.outlineView)
            }
        }
        tagActions.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        tagActions.onCheckout = { [weak self] target in self?.checkoutUseCase.perform(target, worktreePath: nil) }
        stashActions.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        stashActions.onShowDiff = { [weak self] stash in self?.showStash(stash) }
        sidebar.menuItems = { [weak self] subject in MenuAdapter.items(self?.menuBuilder.menu(for: subject.menuSubject, in: .sidebar) ?? []) }
        tagActions.popover.list.menuItems = { [weak self] name in MenuAdapter.items(self?.menuBuilder.menu(for: .tag(name), in: .sidebar) ?? []) }
        stashActions.popover.list.menuItems = { [weak self] id in MenuAdapter.items(self?.menuBuilder.menu(for: .stash(id), in: .sidebar) ?? []) }
        worktreeActions.onSwitchWorktree = { [weak self] path in self?.onSwitchWorktree?(path) }
        sidebar.onNewBranch = { [weak self] in self?.createBranch.show() }
        sidebar.onNewWorktree = { [weak self] in self?.createBranch.show(worktree: true) }
        sidebar.onAddRemote = { [weak self] in self?.remoteActions.showAdd() }
        toolbar.onBranch = { [weak self] in self?.createBranch.show() }

        history.onSelect = { [weak self] row in self?.selectionChanged(to: row) }
        history.onActivate = { [weak self] row, pill in self?.checkoutUseCase.activate(row: row, pill: pill) }
        menuBuilder.operation = { [weak self] in self?.operationBanner.progress?.kind }
        commitActions.squash.operation = { [weak self] in self?.operationBanner.progress?.kind }
        history.menuItems = { [weak self] row in MenuAdapter.items(self?.menuBuilder.rowMenu(forRow: row) ?? []) }
        commitActions.squash.selectedCommitIDs = { [weak self] in
            guard let self else { return [] }
            return history.selectedRows.filter { self.viewModel.commits.indices.contains($0) && (self.viewModel.kinds[$0] == .commit || self.viewModel.kinds[$0] == .merge) }.map { self.viewModel.commits[$0].id }
        }
        history.tableView.onRelative = { [weak self] parent in self?.goToRelative(parent ? .parent : .child) }
        history.pillMenuItems = { [weak self] row, ref in MenuAdapter.items(self?.menuBuilder.pillMenu(forRow: row, ref: ref) ?? []) }

        detail.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        detail.onSelectFiles = { [weak self] files in self?.showDiff(files) }
        detail.onStage = { [weak self] paths in self?.staging.stage(paths) }
        detail.onUnstage = { [weak self] paths in self?.staging.unstage(paths) }
        detail.onDiscard = { [weak self] files in self?.staging.discard(files) }
        detail.onDiscardAll = { [weak self] scope in self?.staging.discardAll(scope) }
        detail.fileMenuItems = { [weak self] files in MenuAdapter.items(self?.menuBuilder.fileMenu(for: files) ?? []) }
        detail.messageAccess = { [weak self] commit in self?.commitActions.interactiveRebase.rewordAccess(for: commit) }
        detail.onEditMessage = { [weak self] in self?.editSelectedCommitMessage() }
        commitActions.interactiveRebase.onReword = { [weak self] commit in self?.editMessage(of: commit) }
        inlineReword.onRewritten = { [weak self] old, new in self?.history.followRewrite(of: old, to: new) }
        inlineReword.onClosed = { [weak self] in self?.messageEditingClosed() }
        fileActions.onChange = { [weak self] in
            self?.reloadDiffs()
            self?.refreshWorkingDirectoryCounts()
        }
        detail.showNothing()
        staging.onChange = { [weak self] in
            self?.reloadDiffs()
            self?.refreshWorkingDirectoryCounts()
        }
        diff.onClose = { [weak self] in self?.showGraph() }
        stackedDiff.onClose = { [weak self] in self?.showGraph() }
        stackedDiff.onFilesGone = { [weak self] gone in
            guard let self else { return }
            detail.selectedFiles.removeAll { gone.contains($0) }
        }
        wireConflicts()
        operationBanner.onAmend = { [weak self] in self?.amendAtEditStop() }
        operationBanner.onEnded = { [weak self] in self?.operationEnded() }
        commitActions.onRebaseEnded = { [weak self] in self?.operationEnded() }
        commitActions.onNewBranch = { [weak self] start in self?.createBranch.show(start: start) }
        pullUseCase.onSwitchWorktree = { [weak self] path in self?.onSwitchWorktree?(path) }
        context.onShowConflicts = { [weak self] in self?.showWorkingDirectory() }
        operationBanner.onStateChange = { [weak self] in
            guard let self else { return }
            rightColumn.showsBar = showsCommitForm(at: singleSelectedRow)
        }
    }
}
