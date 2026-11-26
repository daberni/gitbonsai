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
        didSet { checkoutUseCase.onSwitchWorktree = onSwitchWorktree }
    }
    /// The shown worktree was removed outside the app and the tab moved to the main worktree.
    var onWorktreeReplaced: (() -> Void)?
    var name: String { viewModel.repositoryName }
    var preferredFirstResponder: NSView { history.tableView }

    /// What the tab's controllers share; created by the window for this tab.
    let context: RepositoryContext
    let viewModel: GraphViewModel
    let history: HistoryViewController
    let checkoutUseCase: CheckoutUseCase
    let commitActions: CommitActions
    let fetchUseCase: FetchUseCase
    let upstreamStatus: UpstreamStatus
    let pullUseCase: PullUseCase
    let pushUseCase: PushUseCase
    let operationBanner: OperationBannerController
    let undo: UndoHistory
    var branchActions: BranchActions!
    let worktreeActions: WorktreeActions
    let remoteActions: RemoteActions
    let createBranch: CreateBranchUseCase
    var menuBuilder: MenuBuilder!
    let fastForward: FastForwardUseCase
    let staging: StagingUseCase
    let conflictActions: ConflictActions
    let fileActions: FileActions
    let commitUseCase: CommitUseCase
    let diff: DiffViewController
    /// Takes the diff's place while several files are selected.
    let stackedDiff: StackedDiffController
    /// Takes the diff's place for a file with unresolved conflicts.
    var conflicts: ConflictViewController!
    let tagActions: TagActions
    let stashActions: StashActions
    /// The history column shows the graph, or the diff or conflict view of one file in its place.
    let historyPane = HistoryPaneView()
    /// Detail panel, and below it the commit form for the working directory.
    var rightColumn: ColumnWithBottomBar!
    var split: PanelSplitView!
    /// The panel widths of the window, shared with its other tabs.
    var panelWidths: PanelWidths {
        get { split.widths }
        set { split.widths = newValue }
    }
    var shownStatus: RepositoryStatus?
    /// The commits the detail panel shows, in history order; a different set is a navigation.
    var shownSelection: [String]?
    /// The detail panel's content while several commits are selected.
    var comparison: ComparisonDetail?
    let toolbar = RepositoryToolbar()
    let sidebar: SidebarView
    let detail: DetailView
    var inlineReword: RewordUseCase!
    let statusLabel = NSTextField(labelWithString: "")
    private var didReportLoaded = false
    private var shownSidebarRevision: Int?
    private var shownReadRevision: Int?
    /// The working directory panel was shown afresh during the reconcile under way, so its end need not read it again.
    private var workingDirectoryShownDuringReconcile = false
    var selectsHeadAfterLoad = false
    var toast: Toast { context.toast }

    /// Builds the tab's parts and controllers, each with the context and, where it reads them, the tab's state, and starts loading.
    init(context: RepositoryContext) {
        self.context = context
        viewModel = context.model
        sidebar = SidebarView(sessions: context.app.sessions)
        detail = DetailView(avatars: context.app.avatars, pasteboard: context.app.pasteboard)
        history = HistoryViewController(context: context)
        checkoutUseCase = CheckoutUseCase(context: context)
        commitActions = CommitActions(context: context)
        fetchUseCase = FetchUseCase(context: context)
        upstreamStatus = UpstreamStatus(model: context.model)
        pullUseCase = PullUseCase(context: context, status: upstreamStatus)
        pushUseCase = PushUseCase(context: context, status: upstreamStatus, pull: pullUseCase)
        fastForward = FastForwardUseCase(context: context)
        operationBanner = OperationBannerController(context: context)
        undo = UndoHistory(context: context)
        staging = StagingUseCase(context: context)
        conflictActions = ConflictActions(context: context)
        fileActions = FileActions(context: context, staging: staging, conflicts: conflictActions)
        commitUseCase = CommitUseCase(context: context)
        tagActions = TagActions(context: context)
        stashActions = StashActions(context: context)
        remoteActions = RemoteActions(context: context)
        createBranch = CreateBranchUseCase(context: context)
        worktreeActions = WorktreeActions(context: context)
        let model = viewModel
        let preferences = DiffPreferences(defaults: context.app.persistence.defaults)
        diff = DiffViewController(staging: staging, repository: { model.repository }, preferences: preferences, trace: context.app.trace)
        stackedDiff = StackedDiffController(staging: staging, repository: { model.repository }, preferences: preferences, trace: context.app.trace)
        super.init()
        context.lifecycle.view = view
        conflicts = ConflictViewController(context: context) { [weak self] in self?.conflictSides() ?? ConflictSides(ours: "HEAD", theirs: "MERGE_HEAD") }
        let rebase = commitActions.interactiveRebase
        inlineReword = RewordUseCase(context: context, detail: detail) { [weak rebase] commit in rebase?.rewordAccess(for: commit) }
        let checkout = checkoutUseCase
        branchActions = BranchActions(context: context, pull: pullUseCase, push: pushUseCase, fastForward: fastForward, rebaseOnto: commitActions.rebaseOnto) { target, worktreePath in checkout.perform(target, worktreePath: worktreePath) }
        menuBuilder = MenuBuilder(context: context, checkout: checkoutUseCase, commitActions: commitActions, branches: branchActions, tags: tagActions, fastForward: fastForward, stashes: stashActions, worktrees: worktreeActions, remotes: remoteActions, fetch: fetchUseCase, pull: pullUseCase, push: pushUseCase, files: fileActions, staging: staging)
        wire()
        layout()
        bind()
        viewModel.load()
        startKeepingCurrent()
    }

    /// File watching, reconciling and automatic fetches; the lifecycle owns them and stops them when the tab closes.
    private func startKeepingCurrent() {
        let lifecycle = context.lifecycle
        let autoFetch = AutoFetchScheduler(fetch: { [weak self] in await self?.viewModel.fetch(.allRemotes, background: true) }, lastFetch: { [weak self] in self?.viewModel.lastFetch }, situation: { [weak self] in await self?.autoFetchSituation() ?? .init(hasRemote: false, operationInProgress: false, fetchRunning: false) }, isVisible: { [weak lifecycle] in lifecycle?.isVisible ?? false }, settings: context.settings, trace: context.app.trace)
        let reconciler = TabReconciler(name: viewModel.repositoryName, refresh: { [weak self] in
            self?.workingDirectoryShownDuringReconcile = false
            return await self?.viewModel.reconcile() ?? .loading
        }, isVisible: { [weak lifecycle] in lifecycle?.isVisible ?? false }, trace: context.app.trace)
        reconciler.onReconciled = { [weak self] in self?.reconciled() }
        lifecycle.start(autoFetch: autoFetch, reconciler: reconciler)
        lifecycle.watch(root: viewModel.repository.path)
        viewModel.onWorktreeReplaced = { [weak self] path in
            guard let self else { return }
            context.lifecycle.watch(root: path)
            onWorktreeReplaced?()
        }
    }

    /// The tab became the one its window shows.
    func becameVisible() {
        context.lifecycle.becameVisible()
    }

    /// An open diff stays while its file still has changes there and, for a commit, while the commit is still in the history. A comparison of two revisions never changes, so it is not read again.
    private func reconciled() {
        let files = detail.selectedFiles
        let commitGone = files.contains { if case .commit(let commit) = $0.source { viewModel.rowIndex(of: commit.id) == nil } else { false } }
        let isWorking = files.contains { $0.isStageable || $0.isUnstageable }
        if commitGone {
            showGraph()
        } else if isWorking {
            if historyPane.current === conflicts.view { conflicts.reload() } else if files.count > 1 { stackedDiff.reload() } else { diff.reload() }
        }
        // Editing an already changed file keeps its status line, so the working directory's line counts are read again, unless a changed status just did.
        if !workingDirectoryShownDuringReconcile { refreshWorkingDirectoryCounts() }
        workingDirectoryShownDuringReconcile = false
        context.app.avatars.remotesMayHaveChanged(in: viewModel.repository)
    }

    /// A remote counts once it is configured, before anything was fetched from it.
    func showFetchState() {
        toolbar.fetchBlocked = fetchUseCase.remotes.isEmpty ? UpstreamStatus.noRemote : nil
        toolbar.showFetchState(target: fetchTarget, lastFetch: viewModel.lastFetch, fetching: viewModel.isFetching, failure: viewModel.lastFetchFailure)
    }

    private var fetchTarget: RepositoryToolbar.FetchTarget {
        let remotes = fetchUseCase.remotes
        if let upstream = upstreamStatus.upstream, remotes.isEmpty || remotes.contains(upstream.remote) { return .remote(upstream.remote) }
        if remotes.count > 1 { return .allRemotes }
        if let only = remotes.first { return .remote(only) }
        let hasRemoteBranch = viewModel.refs.contains { if case .remoteBranch = $0.kind { true } else { false } }
        return hasRemoteBranch ? .allRemotes : .none
    }

    private func autoFetchSituation() async -> AutoFetchPolicy.Situation {
        let repository = viewModel.repository
        let hasRemote = await (try? repository.remotes())?.isEmpty == false
        let operation = await repository.operationInProgress()
        return AutoFetchPolicy.Situation(hasRemote: hasRemote, operationInProgress: operation != nil, fetchRunning: viewModel.remoteActivity.running != nil)
    }

    /// The tab closed or its window did: nothing of it runs any more.
    func closed() {
        context.lifecycle.close()
    }

    func switchWorktree(to path: String) {
        viewModel.switchWorktree(to: path)
        context.lifecycle.watch(root: path)
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
        viewModel.onRowsRebuilt = { [weak self] diff, focus in
            if focus == .current { self?.shownSelection = nil }
            self?.history.rowsRebuilt(diff, focus: focus)
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
        commitUseCase.update(status: viewModel.status)
        if viewModel.status != shownStatus { conflictActions.update() }
        // The working directory lists follow every change of the status, for instance after staging.
        if let row = singleSelectedRow, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .wip, viewModel.status != shownStatus {
            showDetail(for: row, keepingFile: true)
            workingDirectoryShownDuringReconcile = true
        }
        showFetchState()
        // Worktree counters and the parts of a first load arrive on their own; git is asked about remotes, upstream and operations once per read of the repository.
        if viewModel.readRevision != shownReadRevision {
            shownReadRevision = viewModel.readRevision
            fetchUseCase.refreshRemotes()
            upstreamStatus.refresh()
            operationBanner.update()
            undo.update()
        }
        selectHeadIfLoaded()
        let hasChanges = !(viewModel.status?.entries.isEmpty ?? true)
        toolbar.stashMenu = hasChanges ? { [weak self] in MenuAdapter.menu(self?.menuBuilder.toolbarMenu(.stash) ?? []) } : nil
        toolbar.onPop = viewModel.stashes.isEmpty ? nil : { [weak self] in self?.stashActions.popNewest() }
        tagActions.viewModelChanged()
        stashActions.viewModelChanged()
        reportLoadedOnce()
    }

    /// Staging or discarding a hunk can leave the status as it was while the line counts change, so the list is read again regardless.
    func refreshWorkingDirectoryCounts() {
        guard let row = singleSelectedRow, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .wip else { return }
        showDetail(for: row, keepingFile: true)
    }

    private func reportLoadedOnce() {
        guard !didReportLoaded, !viewModel.isLoading else { return }
        didReportLoaded = true
        context.lifecycle.loaded()
        onLoaded?()
    }
}
