import AppKit
import GitEngine

/// The content of one repository tab. It puts toolbar, sidebar, history, detail panel and status line together and routes the view model's changes to them.
@MainActor
final class RepositoryViewController: NSObject {
    /// The worktree this tab shows; changes when the tab moves to another worktree.
    var repositoryPath: String { viewModel.repository.path }
    let view: NSView = FillView(color: Theme.surface1)
    /// Called once, when the first full load has finished and the initial selection is set.
    var onLoaded: (() -> Void)?
    /// A worktree was chosen. The window decides whether this tab moves there or another tab already shows it.
    var onSwitchWorktree: ((String) -> Void)? {
        didSet { checkoutController.onSwitchWorktree = onSwitchWorktree }
    }
    var name: String { viewModel.repositoryName }
    var preferredFirstResponder: NSView { history.tableView }

    let viewModel: GraphViewModel
    let history: HistoryViewController
    let checkoutController: CheckoutController
    let commitActions: CommitActionsController
    let fetchController: FetchController
    let pullPush: PullPushController
    let branchPull: BranchPullController
    let operationBanner: OperationBannerController
    let rebaseUndo: RebaseUndoController
    private(set) var sidebarActions: SidebarActionsController!
    private(set) var pillMenu: PillMenuController!
    let staging: StagingController
    let fileActions: FileActionsController
    let commitController: CommitController
    let diff: DiffViewController
    let tagsController: TagsController
    let stashesController: StashesController
    /// The history column shows the graph, or the diff of one file in its place.
    private let historyPane = ContainerView()
    /// Detail panel, and below it the commit form for the working directory.
    private var rightColumn: ColumnWithBottomBar!
    private(set) var split: PanelSplitView!
    /// The panel widths of the window, shared with its other tabs.
    var panelWidths: PanelWidths {
        get { split.widths }
        set { split.widths = newValue }
    }
    private var shownStatus: RepositoryStatus?
    /// The commits the detail panel shows, in history order; a different set is a navigation.
    private var shownSelection: [String]?
    /// The detail panel's content while several commits are selected.
    private(set) var comparison: ComparisonDetail?
    let toolbar = RepositoryToolbar()
    let sidebar = SidebarView()
    private let detail = DetailView()
    private(set) var inlineReword: InlineRewordController!
    private let statusLabel = NSTextField(labelWithString: "")
    private var didReportLoaded = false
    private var shownSidebarRevision: Int?
    private var autoFetch: AutoFetchScheduler?
    private var reconciler: TabReconciler?
    private let commonDirectory: String
    private var selectsHeadAfterLoad = false
    let toast = Toast()

    init(location: RepositoryLocation) {
        viewModel = GraphViewModel(location: location)
        commonDirectory = location.commonDirectory
        history = HistoryViewController(viewModel: viewModel)
        checkoutController = CheckoutController(viewModel: viewModel)
        commitActions = CommitActionsController(viewModel: viewModel)
        fetchController = FetchController(viewModel: viewModel, prompter: commitActions.prompter)
        pullPush = PullPushController(viewModel: viewModel, prompter: commitActions.prompter)
        branchPull = BranchPullController(viewModel: viewModel, pullPush: pullPush)
        operationBanner = OperationBannerController(viewModel: viewModel, prompter: commitActions.prompter)
        rebaseUndo = RebaseUndoController(viewModel: viewModel, prompter: commitActions.prompter)
        staging = StagingController(viewModel: viewModel)
        fileActions = FileActionsController(viewModel: viewModel, staging: staging)
        commitController = CommitController(viewModel: viewModel)
        tagsController = TagsController(viewModel: viewModel)
        stashesController = StashesController(viewModel: viewModel)
        let model = viewModel
        diff = DiffViewController(staging: staging, repository: { model.repository })
        super.init()
        let rebase = commitActions.interactiveRebase
        inlineReword = InlineRewordController(viewModel: viewModel, prompter: commitActions.prompter, detail: detail) { [weak rebase] commit in rebase?.rewordAccess(for: commit) }
        let checkout = checkoutController
        sidebarActions = SidebarActionsController(viewModel: viewModel, branchPull: branchPull, checkout: { target, worktreePath in checkout.perform(target, worktreePath: worktreePath) }, switchWorktree: { [weak self] path in self?.onSwitchWorktree?(path) })
        pillMenu = PillMenuController(viewModel: viewModel, sidebarActions: sidebarActions, tags: tagsController)
        wire()
        layout()
        bind()
        viewModel.load()
        autoFetch = AutoFetchScheduler(fetch: { [weak self] in await self?.viewModel.fetch(.allRemotes) }, lastFetch: { [weak self] in self?.viewModel.lastFetch }, situation: { [weak self] in await self?.autoFetchSituation() ?? .init(hasRemote: false, operationInProgress: false, fetchRunning: false) }, isVisible: { [weak self] in self?.view.window != nil })
        reconciler = TabReconciler(name: viewModel.repositoryName, refresh: { [weak self] in await self?.viewModel.reconcile() ?? .loading }, isVisible: { [weak self] in self?.view.window != nil })
        reconciler?.onReconciled = { [weak self] in self?.reconciled() }
        reconciler?.watch(root: location.root, commonDirectory: location.commonDirectory, gitPath: viewModel.repository.runner.gitPath)
    }

    // MARK: Diff

    /// Opens a file as if it was chosen in the detail panel.
    func openFile(_ selection: FileSelection) {
        detail.selectedFile = selection
        showDiff(selection)
    }

    private func showDiff(_ selection: FileSelection) {
        diff.show(selection) { [weak self] in
            guard let self else { return }
            historyPane.show(diff.view)
        }
    }

    /// The diff's close button or Escape: the graph comes back with the focus.
    private func showGraph() {
        diff.close()
        historyPane.show(history.view)
        detail.selectedFile = nil
        view.window?.makeFirstResponder(history.tableView)
    }

    /// Navigation closes an open diff. The focus goes to the history when it was in the diff or in the file list that opened it, which the new selection replaces;
    /// elsewhere, such as in the search field, it stays, so typing goes on.
    private func closeDiff() {
        diff.close()
        guard historyPane.current === diff.view else { return }
        let focus = view.window?.firstResponder as? NSView
        let focusFollows = focus.map { $0.isDescendant(of: diff.view) || $0.isDescendant(of: detail) } ?? true
        historyPane.show(history.view)
        if focusFollows { view.window?.makeFirstResponder(history.tableView) }
    }

    /// Selects the stash in the history, so the detail panel lists its files, and opens the first one's diff.
    private func showStash(_ stash: Stash) {
        history.navigate(to: stash.commitID)
        guard let row = viewModel.rowIndex(of: stash.commitID) else { return }
        let commit = viewModel.commits[row]
        Task {
            guard let file = try? await viewModel.repository.changedFiles(of: commit).first else { return }
            openFile(FileSelection(path: file.path, originalPath: file.originalPath, source: .commit(commit)))
        }
    }

    /// The tab became the one its window shows.
    func becameVisible() {
        reconciler?.request(.visible)
        autoFetch?.becameVisible()
    }

    /// An open diff stays while its file still has changes there and, for a commit, while the commit is still in the history.
    private func reconciled() {
        if let file = detail.selectedFile {
            if case .commit(let commit) = file.source {
                if viewModel.rowIndex(of: commit.id) == nil { showGraph() }
            } else {
                diff.reload()
            }
        }
        // Editing an already changed file keeps its status line, so the working directory's line counts are read again.
        refreshWorkingDirectoryCounts()
    }

    private func autoFetchSituation() async -> AutoFetchPolicy.Situation {
        let repository = viewModel.repository
        let hasRemote = await (try? repository.remotes())?.isEmpty == false
        let operation = await repository.operationInProgress()
        return AutoFetchPolicy.Situation(hasRemote: hasRemote, operationInProgress: operation != nil, fetchRunning: viewModel.isFetching)
    }

    /// The tab closed or its window did: file events stop.
    func closed() {
        reconciler?.stopWatching()
    }

    func switchWorktree(to path: String) {
        viewModel.switchWorktree(to: path)
        reconciler?.watch(root: path, commonDirectory: commonDirectory, gitPath: viewModel.repository.runner.gitPath)
    }

    // MARK: Wiring

    private func wire() {
        toolbar.onFetch = { [weak self] in self?.fetchController.fetch(.allRemotes) }
        toolbar.fetchMenu = { [weak self] in self?.fetchController.menu() ?? NSMenu() }
        toolbar.pullMenu = { [weak self] in self?.pullPush.pullMenu() ?? NSMenu() }
        toolbar.pushMenu = { [weak self] in self?.pullPush.pushMenu() ?? NSMenu() }
        pullPush.onChange = { [weak self] in
            guard let self else { return }
            toolbar.showUpstream(canPull: pullPush.canPull, canPush: pullPush.canPush, upstream: pullPush.upstream, lacksUpstream: pullPush.lacksUpstream)
        }
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
        toolbar.onBranch = { [weak self] in self?.sidebarActions.newBranch.show() }
        sidebarActions.prompter.window = { [weak self] in self?.view.window }

        history.onSelect = { [weak self] row in self?.selectionChanged(to: row) }
        history.onActivate = { [weak self] row in self?.checkoutController.activate(row: row) }
        history.menuItems = { [weak self] row in
            guard let self else { return [] }
            return commitActions.menuItems(forRow: row, leadingWith: checkoutController.menuItems(forRow: row))
        }
        history.pillMenuItems = { [weak self] row, ref in self?.pillMenu.menuItems(forRow: row, ref: ref) ?? [] }

        detail.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        detail.onSelectFile = { [weak self] selection in self?.showDiff(selection) }
        detail.onStage = { [weak self] paths in self?.staging.stage(paths) }
        detail.onUnstage = { [weak self] paths in self?.staging.unstage(paths) }
        detail.onDiscard = { [weak self] selection in self?.staging.discard(selection) }
        detail.fileMenuItems = { [weak self] file in self?.fileActions.menuItems(for: file) ?? [] }
        detail.messageAccess = { [weak self] commit in self?.commitActions.interactiveRebase.rewordAccess(for: commit) }
        detail.onEditMessage = { [weak self] in self?.editSelectedCommitMessage() }
        commitActions.interactiveRebase.onReword = { [weak self] commit in self?.editMessage(of: commit) }
        inlineReword.onRewritten = { [weak self] old, new in self?.history.followRewrite(of: old, to: new) }
        inlineReword.onClosed = { [weak self] in self?.messageEditingClosed() }
        fileActions.prompter.window = { [weak self] in self?.view.window }
        fileActions.onChange = { [weak self] in
            self?.diff.reload()
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
            self?.diff.reload()
            self?.refreshWorkingDirectoryCounts()
        }
        diff.onClose = { [weak self] in self?.showGraph() }
        operationBanner.onAmend = { [weak self] in self?.amendAtEditStop() }
        operationBanner.onEnded = { [weak self] in self?.operationEnded() }
        commitActions.onRebaseEnded = { [weak self] in self?.operationEnded() }
        commitActions.onToast = { [weak self] text in self?.toast.show(text) }
        branchPull.onToast = { [weak self] text in self?.toast.show(text) }
        branchPull.onSwitchWorktree = { [weak self] path in self?.onSwitchWorktree?(path) }
        operationBanner.onToast = { [weak self] text in self?.toast.show(text) }
        for prompter in [sidebarActions.prompter, fileActions.prompter, commitActions.prompter, tagsController.prompter, stashesController.prompter] {
            prompter.onToast = { [weak self] text, action in self?.toast.show(text, action: action) }
            prompter.onShowConflicts = { [weak self] in self?.showWorkingDirectory() }
        }
        operationBanner.onStateChange = { [weak self] in
            guard let self else { return }
            rightColumn.showsBar = showsCommitForm(at: singleSelectedRow)
        }
    }

    /// Selects the working directory row, where conflicts left by a stash show.
    private func showWorkingDirectory() {
        guard let row = viewModel.kinds.firstIndex(of: .wip) else { return }
        history.select(row: row, scroll: true)
    }

    /// A rebase, cherry-pick, revert or merge is over: the history shows HEAD, and no file or diff of the conflict state stays open.
    /// A rewrite reads the log again, so HEAD may not be a row yet; the selection then waits for the reload.
    private func operationEnded() {
        // The operation moved HEAD on purpose; even an unchanged selection now shows another state.
        shownSelection = nil
        selectionChanged(to: history.selectedRows)
        selectsHeadAfterLoad = true
        selectHeadIfLoaded()
    }

    private func selectHeadIfLoaded() {
        guard selectsHeadAfterLoad, !viewModel.isLoading, let row = viewModel.headSHA.flatMap({ viewModel.rowIndex(of: $0) }) else { return }
        selectsHeadAfterLoad = false
        history.select(row: row, scroll: true)
    }

    // MARK: Message editing

    /// The one commit selected, when it is a commit and not the working directory or a stash.
    var selectedCommitForMessage: Commit? {
        guard let row = singleSelectedRow, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .commit || viewModel.kinds[row] == .merge else { return nil }
        return viewModel.commits[row]
    }

    /// Why ⌘E cannot edit the selected commit's message right now; nil when it can.
    var editMessageReason: LocalizedStringResource? {
        guard let commit = selectedCommitForMessage else { return "No commit selected" }
        if inlineReword.isEditing { return "Already being edited" }
        switch commitActions.interactiveRebase.rewordAccess(for: commit) {
        case .allowed: return nil
        case let .disabled(reason): return .verbatim(reason)
        case nil: return viewModel.currentBranch.map { "Not in the history of \($0)" } ?? "Detached HEAD"
        }
    }

    func editSelectedCommitMessage() {
        guard let commit = selectedCommitForMessage else { return NSSound.beep() }
        inlineReword.begin(commit)
    }

    /// From the commit menu the commit may not be the selected one; it is selected first, so the panel shows it.
    private func editMessage(of commit: Commit) {
        if selectedCommitForMessage?.id != commit.id { history.navigate(to: commit.id) }
        inlineReword.begin(commit)
    }

    /// The focus goes back to the history. After a reword the panel shows the selected commit afresh, so no editor of a commit that is gone stays open.
    private func messageEditingClosed() {
        if detail.messageEditor != nil {
            shownSelection = nil
            selectionChanged(to: history.selectedRows)
        }
        view.window?.makeFirstResponder(history.tableView)
    }

    /// At an edit stop the commit form amends the stopped commit: shown under the working directory, or under HEAD while nothing changed.
    private func amendAtEditStop() {
        guard let row = viewModel.currentRow else { return }
        history.select(row: row, scroll: true)
        rightColumn.showsBar = true
        commitController.beginAmend()
    }

    private func showsCommitForm(at row: Int?) -> Bool {
        guard let row, viewModel.kinds.indices.contains(row) else { return false }
        return viewModel.kinds[row] == .wip || operationBanner.isEditStop && viewModel.commits[row].id == viewModel.headSHA
    }

    /// The one rule for every way the history selection moves: a click or arrow key, ⌘- or ⇧-click, the parent link, the sidebar, tags and stashes, the search,
    /// a checkout or worktree switch, a commit that left the history, the end of a rebase. Another set of selected commits than the one shown closes an open diff and shows the new selection.
    /// The same commits again, as after staging, leave diff and panel as they are; changes of the working directory reach the panel through `metadataChanged`.
    /// The table clears its selection for a moment while it is rebuilt; that is no change either.
    private func selectionChanged(to rows: IndexSet) {
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
    private var singleSelectedRow: Int? {
        history.selectedRows.count == 1 ? history.selectedRows.first : nil
    }

    /// The base switch replaces the files; an open diff moves to the same file in the new comparison, or closes when it is not part of it.
    private func showComparison(of rows: IndexSet) {
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
    private func showDetail(for row: Int?, keepingFile: Bool = false) {
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

    // MARK: Layout

    private func layout() {
        let sidebarScroll = Self.scroll(sidebar, background: Theme.surface1)
        let detailScroll = Self.scroll(detail, background: Theme.surface1)
        Self.fitToContent(detail, in: detailScroll)
        // The banner of a rebase, cherry-pick or revert in progress sits above the history and takes no room while hidden.
        let historyColumn = NSStackView(views: [operationBanner.view, historyPane])
        historyColumn.orientation = .vertical
        historyColumn.spacing = 0
        for part in [operationBanner.view, historyPane] {
            part.leadingAnchor.constraint(equalTo: historyColumn.leadingAnchor).isActive = true
            part.trailingAnchor.constraint(equalTo: historyColumn.trailingAnchor).isActive = true
        }
        historyPane.setContentHuggingPriority(.defaultLow, for: .vertical)
        historyPane.show(history.view)
        // The commit form sits below the detail panel and only appears for the working directory.
        rightColumn = ColumnWithBottomBar(content: detailScroll, bar: commitController.form)
        split = PanelSplitView(sidebar: sidebarScroll, history: historyColumn, detail: rightColumn)

        let statusBar = BarView(edge: .top)
        statusLabel.font = Theme.captionDigits
        statusLabel.textColor = Theme.inkMuted
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)
        rebaseUndo.button.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(rebaseUndo.button)

        for subview in [toolbar, split, statusBar] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Theme.Window.toolbar),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: Theme.Window.statusBar),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: Theme.Space.m),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            rebaseUndo.button.leadingAnchor.constraint(greaterThanOrEqualTo: statusLabel.trailingAnchor, constant: Theme.Space.s),
            rebaseUndo.button.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -Theme.Space.m),
            rebaseUndo.button.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
        toast.install(in: view, above: historyPane)
    }

    /// A document view laid out with constraints grows with its content, and never gets shorter than the visible area.
    private static func fitToContent(_ document: NSView, in scrollView: NSScrollView) {
        let clip = scrollView.contentView
        document.translatesAutoresizingMaskIntoConstraints = false
        let collapse = document.heightAnchor.constraint(equalToConstant: 0)
        // Weaker than anything around it: it only shrinks the document, never the scroll view.
        collapse.priority = NSLayoutConstraint.Priority(1)
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            collapse,
        ])
    }

    private static func scroll(_ document: NSView, background: NSColor) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = document
        document.autoresizingMask = [.width]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        return scrollView
    }

    // MARK: Binding

    private func bind() {
        viewModel.onRowsAppended = { [weak self] range in self?.history.rowsAppended(range) }
        // A checkout or worktree switch moves the working tree on purpose: even the same row selected again is a navigation.
        viewModel.onReset = { [weak self] focus in
            if focus == .current { self?.shownSelection = nil }
            self?.history.rowsReset(focus: focus)
        }
        viewModel.onRowsShifted = { [weak self] in self?.history.rowsShifted() }
        viewModel.onRowsRebuilt = { [weak self] focus in
            if focus == .current { self?.shownSelection = nil }
            self?.history.rowsRebuilt(focus: focus)
        }
        viewModel.onMetadataChanged = { [weak self] in self?.metadataChanged() }
        viewModel.onStatusChanged = { [weak self] text in self?.statusLabel.stringValue = text }
    }

    private func metadataChanged() {
        if let revision = viewModel.sidebarRevision, revision != shownSidebarRevision {
            shownSidebarRevision = revision
            sidebar.reload(from: viewModel)
        }
        history.metadataChanged()
        commitController.update(status: viewModel.status)
        // The working directory lists follow every change of the status, for instance after staging.
        if let row = singleSelectedRow, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .wip, viewModel.status != shownStatus {
            showDetail(for: row, keepingFile: true)
        }
        let hasRemote = viewModel.refs.contains { if case .remoteBranch = $0.kind { true } else { false } }
        toolbar.showFetchState(hasRemote: hasRemote, lastFetch: viewModel.lastFetch)
        fetchController.refreshRemotes()
        pullPush.refresh()
        operationBanner.update()
        rebaseUndo.update()
        selectHeadIfLoaded()
        let hasChanges = !(viewModel.status?.entries.isEmpty ?? true)
        toolbar.stashMenu = hasChanges ? { [weak self] in self?.stashesController.stashMenu() ?? NSMenu() } : nil
        toolbar.onPop = viewModel.stashes.isEmpty ? nil : { [weak self] in self?.stashesController.popNewest() }
        tagsController.viewModelChanged()
        stashesController.viewModelChanged()
        reportLoadedOnce()
    }

    /// Staging or discarding a hunk can leave the status as it was while the line counts change, so the list is read again regardless.
    private func refreshWorkingDirectoryCounts() {
        guard let row = singleSelectedRow, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .wip else { return }
        showDetail(for: row, keepingFile: true)
    }

    private func reportLoadedOnce() {
        guard !didReportLoaded, !viewModel.isLoading else { return }
        didReportLoaded = true
        if ScreenshotHarness.outputPath != nil {
            // A one-time action reloads the tab; the capture waits for the next full load.
            if ScreenshotHarness.runOneTimeAction(on: self) {
                didReportLoaded = false
                return
            }
            ScreenshotHarness.prepare(history)
            ScreenshotHarness.driveHistoryContents(on: self)
            ScreenshotHarness.driveStatusLine(on: self)
            ScreenshotHarness.openDiff(on: self)
            ScreenshotHarness.clickFile(on: self)
            ScreenshotHarness.pressFileKeys(on: self)
            ScreenshotHarness.traceDetail(on: self)
            ScreenshotHarness.fillCommit(on: self)
            ScreenshotHarness.discard(on: self)
            ScreenshotHarness.fileMenu(on: self)
            ScreenshotHarness.scrollSidebar(sidebar)
            ScreenshotHarness.printSidebarGutter(sidebar)
            ScreenshotHarness.openCommitMenu(on: self)
            ScreenshotHarness.runRemotesAndRebase(on: self)
            ScreenshotHarness.driveStashesAndTags(on: self)
            ScreenshotHarness.openSidebarMenu(on: self)
            ScreenshotHarness.printStatusLine(of: self)
            ScreenshotHarness.driveRebase(on: self)
            ScreenshotHarness.navigate(on: self)
        }
        autoFetch?.loaded()
        reconciler?.loaded()
        ScreenshotHarness.runReturnRefreshSteps(on: self)
        onLoaded?()
    }
}
