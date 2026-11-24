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
    /// The shown worktree was removed outside the app and the tab moved to the main worktree.
    var onWorktreeReplaced: (() -> Void)?
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
    let undo: UndoController
    var sidebarActions: SidebarActionsController!
    var historyMenu: HistoryMenuController!
    let fastForward: FastForwardController
    let staging: StagingController
    let fileActions: FileActionsController
    let commitController: CommitController
    let diff: DiffViewController
    /// Takes the diff's place while several files are selected.
    let stackedDiff: StackedDiffController
    /// Takes the diff's place for a file with unresolved conflicts.
    var conflicts: ConflictViewController!
    let tagsController: TagsController
    let stashesController: StashesController
    /// The history column shows the graph, or the diff or conflict view of one file in its place.
    let historyPane = ContainerView()
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
    let sidebar = SidebarView()
    let detail = DetailView()
    var inlineReword: InlineRewordController!
    let statusLabel = NSTextField(labelWithString: "")
    private var didReportLoaded = false
    private var shownSidebarRevision: Int?
    private var shownReadRevision: Int?
    /// The working directory panel was shown afresh during the reconcile under way, so its end need not read it again.
    private var workingDirectoryShownDuringReconcile = false
    private var autoFetch: AutoFetchScheduler?
    private var reconciler: TabReconciler?
    private let commonDirectory: String
    var selectsHeadAfterLoad = false
    let toast = Toast()
    /// Questions and reports that arrived while the tab was in the background, waiting for it to be shown.
    private var shownWaiters: [CheckedContinuation<NSWindow?, Never>] = []

    init(location: RepositoryLocation) {
        viewModel = GraphViewModel(location: location)
        commonDirectory = location.commonDirectory
        history = HistoryViewController(viewModel: viewModel)
        checkoutController = CheckoutController(viewModel: viewModel)
        commitActions = CommitActionsController(viewModel: viewModel)
        fetchController = FetchController(viewModel: viewModel, prompter: commitActions.prompter)
        pullPush = PullPushController(viewModel: viewModel, prompter: commitActions.prompter)
        branchPull = BranchPullController(viewModel: viewModel, pullPush: pullPush)
        fastForward = FastForwardController(viewModel: viewModel, prompter: commitActions.prompter)
        operationBanner = OperationBannerController(viewModel: viewModel, prompter: commitActions.prompter)
        undo = UndoController(viewModel: viewModel, prompter: commitActions.prompter)
        staging = StagingController(viewModel: viewModel)
        fileActions = FileActionsController(viewModel: viewModel, staging: staging)
        commitController = CommitController(viewModel: viewModel)
        tagsController = TagsController(viewModel: viewModel)
        stashesController = StashesController(viewModel: viewModel)
        let model = viewModel
        diff = DiffViewController(staging: staging, repository: { model.repository })
        stackedDiff = StackedDiffController(staging: staging, repository: { model.repository })
        super.init()
        conflicts = ConflictViewController(repository: { model.repository }, sides: { [weak self] in self?.conflictSides() ?? ConflictSides(ours: "HEAD", theirs: "MERGE_HEAD") }, refresh: { await model.refresh(note: nil) }, prompter: commitActions.prompter)
        let rebase = commitActions.interactiveRebase
        inlineReword = InlineRewordController(viewModel: viewModel, prompter: commitActions.prompter, detail: detail) { [weak rebase] commit in rebase?.rewordAccess(for: commit) }
        let checkout = checkoutController
        sidebarActions = SidebarActionsController(viewModel: viewModel, branchPull: branchPull, fastForward: fastForward, checkout: { target, worktreePath in checkout.perform(target, worktreePath: worktreePath) }, switchWorktree: { [weak self] path in self?.onSwitchWorktree?(path) })
        historyMenu = HistoryMenuController(viewModel: viewModel, checkout: checkoutController, commitActions: commitActions, branches: sidebarActions.branches, tags: tagsController, fastForward: fastForward)
        wire()
        layout()
        bind()
        viewModel.load()
        autoFetch = AutoFetchScheduler(fetch: { [weak self] in await self?.viewModel.fetch(.allRemotes, background: true) }, lastFetch: { [weak self] in self?.viewModel.lastFetch }, situation: { [weak self] in await self?.autoFetchSituation() ?? .init(hasRemote: false, operationInProgress: false, fetchRunning: false) }, isVisible: { [weak self] in self?.view.window != nil })
        reconciler = TabReconciler(name: viewModel.repositoryName, refresh: { [weak self] in
            self?.workingDirectoryShownDuringReconcile = false
            return await self?.viewModel.reconcile() ?? .loading
        }, isVisible: { [weak self] in self?.view.window != nil })
        reconciler?.onReconciled = { [weak self] in self?.reconciled() }
        reconciler?.watch(root: location.root, commonDirectory: location.commonDirectory, gitPath: viewModel.repository.runner.gitPath)
        viewModel.onWorktreeReplaced = { [weak self] path in
            guard let self else { return }
            reconciler?.watch(root: path, commonDirectory: commonDirectory, gitPath: viewModel.repository.runner.gitPath)
            onWorktreeReplaced?()
        }
    }

    /// The tab became the one its window shows.
    func becameVisible() {
        reconciler?.request(.visible)
        autoFetch?.becameVisible()
        resumeShownWaiters(with: view.window)
    }

    /// The tab's window, at once while it is shown, otherwise once the tab is shown again; nil when the tab closes first.
    func windowWhenShown() async -> NSWindow? {
        if let window = view.window { return window }
        return await withCheckedContinuation { shownWaiters.append($0) }
    }

    private func resumeShownWaiters(with window: NSWindow?) {
        let waiters = shownWaiters
        shownWaiters = []
        for waiter in waiters { waiter.resume(returning: window) }
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
        AvatarStore.shared.remotesMayHaveChanged(in: viewModel.repository)
    }

    /// A remote counts once it is configured, before anything was fetched from it.
    func showFetchState() {
        toolbar.showFetchState(target: fetchTarget, lastFetch: viewModel.lastFetch, fetching: viewModel.isFetching, failure: viewModel.lastFetchFailure)
    }

    private var fetchTarget: RepositoryToolbar.FetchTarget {
        let remotes = fetchController.remotes
        if let upstream = pullPush.upstream, remotes.isEmpty || remotes.contains(upstream.remote) { return .remote(upstream.remote) }
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

    /// The tab closed or its window did: file events stop.
    func closed() {
        resumeShownWaiters(with: nil)
        reconciler?.stopWatching()
        viewModel.close()
    }

    func switchWorktree(to path: String) {
        viewModel.switchWorktree(to: path)
        reconciler?.watch(root: path, commonDirectory: commonDirectory, gitPath: viewModel.repository.runner.gitPath)
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
        commitController.update(status: viewModel.status)
        // The working directory lists follow every change of the status, for instance after staging.
        if let row = singleSelectedRow, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .wip, viewModel.status != shownStatus {
            showDetail(for: row, keepingFile: true)
            workingDirectoryShownDuringReconcile = true
        }
        showFetchState()
        // Worktree counters and the parts of a first load arrive on their own; git is asked about remotes, upstream and operations once per read of the repository.
        if viewModel.readRevision != shownReadRevision {
            shownReadRevision = viewModel.readRevision
            fetchController.refreshRemotes()
            pullPush.refresh()
            operationBanner.update()
            undo.update()
        }
        selectHeadIfLoaded()
        let hasChanges = !(viewModel.status?.entries.isEmpty ?? true)
        toolbar.stashMenu = hasChanges ? { [weak self] in self?.stashesController.stashMenu() ?? NSMenu() } : nil
        toolbar.onPop = viewModel.stashes.isEmpty ? nil : { [weak self] in self?.stashesController.popNewest() }
        tagsController.viewModelChanged()
        stashesController.viewModelChanged()
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
        // A one-time action of the harness reloads the tab; the capture waits for the next full load.
        if ScreenshotHarness.driveLoadedTab(self) {
            didReportLoaded = false
            return
        }
        autoFetch?.loaded()
        reconciler?.loaded()
        ScreenshotHarness.runReturnRefreshSteps(on: self)
        onLoaded?()
    }
}
