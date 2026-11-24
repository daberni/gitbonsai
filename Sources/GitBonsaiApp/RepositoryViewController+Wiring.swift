import AppKit
import GitEngine

/// Connects the tab's parts and controllers to each other.
extension RepositoryViewController {
    // MARK: Wiring

    func wire() {
        toolbar.onFetch = { [weak self] in self?.fetchController.fetch(.allRemotes) }
        toolbar.fetchMenu = { [weak self] in self?.fetchController.menu() ?? NSMenu() }
        fetchController.onRemotesChanged = { [weak self] in
            guard let self else { return }
            showFetchState()
            sidebar.remotes = fetchController.remotes
            sidebar.reload(from: viewModel)
        }
        toolbar.pullMenu = { [weak self] in self?.pullPush.pullMenu() ?? NSMenu() }
        toolbar.pushMenu = { [weak self] in self?.pullPush.pushMenu() ?? NSMenu() }
        pullPush.onChange = { [weak self] in
            guard let self else { return }
            toolbar.showUpstream(canPull: pullPush.canPull, canPush: pullPush.canPush, upstream: pullPush.upstream, lacksUpstream: pullPush.lacksUpstream)
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
        sidebar.onCheckout = { [weak self] target, worktreePath in self?.checkoutController.perform(target, worktreePath: worktreePath) }
        sidebar.onSwitchWorktree = { [weak self] path in self?.onSwitchWorktree?(path) }
        sidebar.onOpenPanel = { [weak self] panel, anchor in
            guard let self else { return }
            switch panel {
            case .tags: tagsController.show(relativeTo: anchor, of: sidebar)
            case .stashes: stashesController.show(relativeTo: anchor, of: sidebar)
            }
        }
        tagsController.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        tagsController.onCheckout = { [weak self] target in self?.checkoutController.perform(target, worktreePath: nil) }
        stashesController.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        stashesController.onShowDiff = { [weak self] stash in self?.showStash(stash) }
        sidebar.menuItems = { [weak self] subject in self?.sidebarActions.menuItems(for: subject) ?? [] }
        sidebar.onNewBranch = { [weak self] in self?.sidebarActions.newBranch.show() }
        sidebar.onNewWorktree = { [weak self] in self?.sidebarActions.newBranch.show(worktree: true) }
        sidebar.onAddRemote = { [weak self] in self?.sidebarActions.remotes.showAdd() }
        toolbar.onBranch = { [weak self] in self?.sidebarActions.newBranch.show() }
        sidebarActions.prompter.window = { [weak self] in self?.view.window }

        history.onSelect = { [weak self] row in self?.selectionChanged(to: row) }
        history.onActivate = { [weak self] row, pill in self?.checkoutController.activate(row: row, pill: pill) }
        history.menuItems = { [weak self] row in self?.historyMenu.rowMenu(forRow: row) ?? [] }
        commitActions.squash.selectedCommitIDs = { [weak self] in
            guard let self else { return [] }
            return history.selectedRows.filter { self.viewModel.commits.indices.contains($0) && (self.viewModel.kinds[$0] == .commit || self.viewModel.kinds[$0] == .merge) }.map { self.viewModel.commits[$0].id }
        }
        history.tableView.onRelative = { [weak self] parent in self?.goToRelative(parent ? .parent : .child) }
        history.pillMenuItems = { [weak self] row, ref in self?.historyMenu.pillMenu(forRow: row, ref: ref) ?? [] }

        detail.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        detail.onSelectFiles = { [weak self] files in self?.showDiff(files) }
        detail.onStage = { [weak self] paths in self?.staging.stage(paths) }
        detail.onUnstage = { [weak self] paths in self?.staging.unstage(paths) }
        detail.onDiscard = { [weak self] files in self?.staging.discard(files) }
        detail.fileMenuItems = { [weak self] files in self?.fileActions.menuItems(for: files) ?? [] }
        detail.messageAccess = { [weak self] commit in self?.commitActions.interactiveRebase.rewordAccess(for: commit) }
        detail.onEditMessage = { [weak self] in self?.editSelectedCommitMessage() }
        commitActions.interactiveRebase.onReword = { [weak self] commit in self?.editMessage(of: commit) }
        inlineReword.onRewritten = { [weak self] old, new in self?.history.followRewrite(of: old, to: new) }
        inlineReword.onClosed = { [weak self] in self?.messageEditingClosed() }
        fileActions.prompter.window = { [weak self] in self?.view.window }
        fileActions.onChange = { [weak self] in
            self?.reloadDiffs()
            self?.refreshWorkingDirectoryCounts()
        }
        detail.showNothing()
        checkoutController.window = { [weak self] in self?.view.window }
        commitActions.prompter.window = { [weak self] in self?.view.window }
        tagsController.prompter.window = { [weak self] in self?.view.window }
        stashesController.prompter.window = { [weak self] in self?.view.window }
        staging.window = { [weak self] in self?.view.window }
        commitController.window = { [weak self] in self?.view.window }
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
        commitActions.onToast = { [weak self] text in self?.toast.show(text) }
        commitActions.onNewBranch = { [weak self] commit in self?.sidebarActions.newBranch.show(commit: commit) }
        branchPull.onToast = { [weak self] text in self?.toast.show(text) }
        fastForward.onToast = { [weak self] text in self?.toast.show(text) }
        branchPull.onSwitchWorktree = { [weak self] path in self?.onSwitchWorktree?(path) }
        operationBanner.onToast = { [weak self] text in self?.toast.show(text) }
        for prompter in [sidebarActions.prompter, fileActions.prompter, commitActions.prompter, tagsController.prompter, stashesController.prompter] {
            prompter.onToast = { [weak self] text, action in self?.toast.show(text, action: action) }
            prompter.onShowConflicts = { [weak self] in self?.showWorkingDirectory() }
            prompter.whenShown = { [weak self] in await self?.windowWhenShown() }
        }
        operationBanner.onStateChange = { [weak self] in
            guard let self else { return }
            rightColumn.showsBar = showsCommitForm(at: singleSelectedRow)
        }
    }
}
