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
    /// The repository name became known or changed.
    var onNameChanged: (() -> Void)?
    var name: String { viewModel.repositoryName }
    var preferredFirstResponder: NSView { history.tableView }

    let viewModel: GraphViewModel
    let history: HistoryViewController
    let checkoutController: CheckoutController
    let staging: StagingController
    let commitController: CommitController
    let diff: DiffViewController
    /// The history column shows the graph, or the diff of one file in its place.
    private let historyPane = ContainerView()
    /// Detail panel, and below it the commit form for the working directory.
    private var rightColumn: ColumnWithBottomBar!
    private var shownStatus: RepositoryStatus?
    private var shownCommitID: String?
    private let toolbar = RepositoryToolbar()
    private let sidebar = SidebarView()
    private let detail = DetailView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var didReportLoaded = false
    private var lastReportedName = ""

    init(repositoryPath: String) {
        viewModel = GraphViewModel(repositoryPath: repositoryPath)
        history = HistoryViewController(viewModel: viewModel)
        checkoutController = CheckoutController(viewModel: viewModel)
        staging = StagingController(viewModel: viewModel)
        commitController = CommitController(viewModel: viewModel)
        let model = viewModel
        diff = DiffViewController(staging: staging, repository: { model.repository })
        super.init()
        wire()
        layout()
        bind()
        viewModel.load()
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

    private func showGraph() {
        historyPane.show(history.view)
        detail.selectedFile = nil
        view.window?.makeFirstResponder(history.tableView)
    }

    func switchWorktree(to path: String) {
        viewModel.switchWorktree(to: path)
    }

    // MARK: Wiring

    private func wire() {
        toolbar.onFetch = { [weak self] in
            guard let self else { return }
            Task { await self.viewModel.fetch() }
        }
        toolbar.onSearch = { [weak self] text in self?.history.search(text) }

        sidebar.onSelectCommit = { [weak self] sha in self?.history.navigate(to: sha) }
        sidebar.onCheckout = { [weak self] target, worktreePath in self?.checkoutController.perform(target, worktreePath: worktreePath) }
        sidebar.onSwitchWorktree = { [weak self] path in self?.onSwitchWorktree?(path) }

        history.onSelect = { [weak self] row in self?.selectionChanged(to: row) }
        history.onActivate = { [weak self] row in self?.checkoutController.activate(row: row) }
        history.menuItems = { [weak self] row in self?.checkoutController.menuItems(forRow: row) ?? [] }

        detail.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        detail.onSelectFile = { [weak self] selection in self?.showDiff(selection) }
        detail.onStage = { [weak self] paths in self?.staging.stage(paths) }
        detail.onUnstage = { [weak self] paths in self?.staging.unstage(paths) }
        detail.onDiscard = { [weak self] selection in self?.staging.discard(selection) }
        detail.showNothing()
        checkoutController.window = { [weak self] in self?.view.window }
        staging.window = { [weak self] in self?.view.window }
        commitController.window = { [weak self] in self?.view.window }
        staging.onChange = { [weak self] in
            self?.diff.reload()
            self?.refreshWorkingDirectoryCounts()
        }
        diff.onClose = { [weak self] in self?.showGraph() }
    }

    /// The table clears its selection for a moment while it is rebuilt, and then selects the same row again; neither counts as a change.
    /// Selecting the same commit again leaves the panel as it is; changes of the working directory reach it through `metadataChanged`.
    private func selectionChanged(to row: Int?) {
        guard let row else { return }
        let id = viewModel.commits[row].id
        guard id != shownCommitID else { return }
        shownCommitID = id
        showDetail(for: row)
    }

    /// A new selection in the history starts without a chosen file; a redraw of the same one keeps it.
    private func showDetail(for row: Int?, keepingFile: Bool = false) {
        if !keepingFile { detail.selectedFile = nil }
        rightColumn.showsBar = row.map { viewModel.kinds[$0] == .wip } ?? false
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
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        let sidebarScroll = Self.scroll(sidebar, background: Theme.surface1)
        let detailScroll = Self.scroll(detail, background: Theme.surface1)
        Self.fitToContent(detail, in: detailScroll)
        split.addArrangedSubview(sidebarScroll)
        split.addArrangedSubview(historyPane)
        historyPane.show(history.view)
        // The commit form sits below the detail panel and only appears for the working directory.
        rightColumn = ColumnWithBottomBar(content: detailScroll, bar: commitController.form)
        split.addArrangedSubview(rightColumn)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        sidebarScroll.widthAnchor.constraint(equalToConstant: Theme.Window.sidebarWidth).isActive = true
        rightColumn.widthAnchor.constraint(equalToConstant: Theme.Window.detailWidth).isActive = true

        let statusBar = BarView(edge: .top)
        statusLabel.font = Theme.captionDigits
        statusLabel.textColor = Theme.inkMuted
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)

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
        ])
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
        viewModel.onReset = { [weak self] in self?.history.rowsReset() }
        viewModel.onRowsShifted = { [weak self] in self?.history.rowsShifted() }
        viewModel.onRowsRebuilt = { [weak self] in self?.history.rowsRebuilt() }
        viewModel.onMetadataChanged = { [weak self] in self?.metadataChanged() }
        viewModel.onStatusChanged = { [weak self] text in self?.statusLabel.stringValue = text }
    }

    private func metadataChanged() {
        if name != lastReportedName {
            lastReportedName = name
            onNameChanged?()
        }
        sidebar.reload(from: viewModel)
        history.metadataChanged()
        commitController.update(status: viewModel.status)
        // The working directory lists follow every change of the status, for instance after staging.
        if let row = history.selectedRow >= 0 ? history.selectedRow : nil, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .wip, viewModel.status != shownStatus {
            showDetail(for: row, keepingFile: true)
        }
        let hasRemote = viewModel.refs.contains { if case .remoteBranch = $0.kind { true } else { false } }
        toolbar.showFetchState(hasRemote: hasRemote, lastFetch: viewModel.lastFetch)
        reportLoadedOnce()
    }

    /// Staging or discarding a hunk can leave the status as it was while the line counts change, so the list is read again regardless.
    private func refreshWorkingDirectoryCounts() {
        let row = history.selectedRow
        guard row >= 0, viewModel.kinds.indices.contains(row), viewModel.kinds[row] == .wip else { return }
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
            ScreenshotHarness.openDiff(on: self)
            ScreenshotHarness.clickFile(on: self)
            ScreenshotHarness.fillCommit(on: self)
            ScreenshotHarness.discard(on: self)
        }
        onLoaded?()
    }
}
