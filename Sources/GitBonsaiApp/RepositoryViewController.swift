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
        super.init()
        wire()
        layout()
        bind()
        viewModel.load()
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

        history.onSelect = { [weak self] row in self?.showDetail(for: row) }
        history.onActivate = { [weak self] row in self?.checkoutController.activate(row: row) }
        history.menuItems = { [weak self] row in self?.checkoutController.menuItems(forRow: row) ?? [] }

        detail.onNavigate = { [weak self] sha in self?.history.navigate(to: sha) }
        detail.showNothing()
        checkoutController.window = { [weak self] in self?.view.window }
    }

    private func showDetail(for row: Int?) {
        guard let row else { detail.showNothing(); return }
        if viewModel.kinds[row] == .wip, let status = viewModel.status {
            detail.showWorkingDirectory(status: status)
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
        split.addArrangedSubview(sidebarScroll)
        split.addArrangedSubview(history.view)
        split.addArrangedSubview(detailScroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        sidebarScroll.widthAnchor.constraint(equalToConstant: Theme.Window.sidebarWidth).isActive = true
        detailScroll.widthAnchor.constraint(equalToConstant: Theme.Window.detailWidth).isActive = true

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
        let hasRemote = viewModel.refs.contains { if case .remoteBranch = $0.kind { true } else { false } }
        toolbar.showFetchState(hasRemote: hasRemote, lastFetch: viewModel.lastFetch)
        reportLoadedOnce()
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
        }
        onLoaded?()
    }
}
