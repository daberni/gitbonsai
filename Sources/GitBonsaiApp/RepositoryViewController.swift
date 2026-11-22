import AppKit
import GitEngine
import GraphLayout

/// The content of one repository tab: toolbar row, then sidebar, history and detail panel side by side, then the status line.
@MainActor
final class RepositoryViewController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let repositoryPath: String
    let view: NSView = FillView(color: Theme.surface1)
    /// Called once, when the first full load has finished and the initial selection is set.
    var onLoaded: (() -> Void)?
    var name: String { URL(fileURLWithPath: repositoryPath).lastPathComponent }
    var preferredFirstResponder: NSView { tableView }

    private let viewModel: GraphViewModel
    private let tableView = NSTableView()
    private let headerView = HistoryHeaderView()
    private let sidebar = SidebarView()
    private let detail = DetailView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let fetchLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private var graphWidth: CGFloat = Theme.Graph.firstLane + Theme.Graph.lane
    private var selectedRow = -1
    private var didReportLoaded = false

    init(repositoryPath: String) {
        self.repositoryPath = repositoryPath
        viewModel = GraphViewModel(repositoryPath: repositoryPath)
        super.init()
        buildContent()
        bind()
        viewModel.load()
    }

    // MARK: Layout

    private func buildContent() {
        let toolbar = makeToolbar()
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        let sidebarScroll = scroll(sidebar, background: Theme.surface1)
        sidebar.autoresizingMask = [.width]
        sidebar.onSelectCommit = { [weak self] sha in self?.navigate(to: sha) }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Theme.Graph.rowHeight
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = Theme.surface0
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        let column = NSTableColumn(identifier: .init("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let historyScroll = scroll(tableView, background: Theme.surface0)
        let history = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        history.addSubview(headerView)
        history.addSubview(historyScroll)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: history.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: history.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: history.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 30),
            historyScroll.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            historyScroll.leadingAnchor.constraint(equalTo: history.leadingAnchor),
            historyScroll.trailingAnchor.constraint(equalTo: history.trailingAnchor),
            historyScroll.bottomAnchor.constraint(equalTo: history.bottomAnchor),
        ])

        let detailScroll = scroll(detail, background: Theme.surface1)
        detail.autoresizingMask = [.width]
        detail.onNavigate = { [weak self] sha in self?.navigate(to: sha) }
        detail.showNothing()

        split.addArrangedSubview(sidebarScroll)
        split.addArrangedSubview(history)
        split.addArrangedSubview(detailScroll)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        split.setHoldingPriority(.defaultHigh, forSubviewAt: 2)
        sidebarScroll.widthAnchor.constraint(equalToConstant: 264).isActive = true
        detailScroll.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let statusBar = BarView(edge: .top)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = Theme.inkMuted
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBar.addSubview(statusLabel)

        let content = view
        for view in [toolbar, split, statusBar] { content.addSubview(view) }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),
            split.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
    }

    private func scroll(_ document: NSView, background: NSColor) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.documentView = document
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }

    /// Three parts: fetch status on the left, the actions centred in the window, search on the right.
    private func makeToolbar() -> NSView {
        let bar = BarView(edge: .bottom)
        bar.translatesAutoresizingMaskIntoConstraints = false
        fetchLabel.font = Theme.caption
        fetchLabel.textColor = Theme.inkMuted
        fetchLabel.translatesAutoresizingMaskIntoConstraints = false

        func button(_ title: String, _ symbol: String, _ action: Selector?, enabled: Bool) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = .rounded
            button.isEnabled = enabled
            if !enabled { button.toolTip = "Kommt mit dem MVP" }
            return button
        }
        let actions = NSStackView(views: [
            button("Fetch", "arrow.down.to.line", #selector(fetch(_:)), enabled: true),
            button("Pull", "arrow.down", nil, enabled: false),
            button("Push", "arrow.up", nil, enabled: false),
            button("Branch", "arrow.triangle.branch", nil, enabled: false),
            button("Stash", "tray.and.arrow.down", nil, enabled: false),
            button("Pop", "tray.and.arrow.up", nil, enabled: false),
        ])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Commits durchsuchen"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(search(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        for view in [fetchLabel, actions, searchField] { bar.addSubview(view) }
        NSLayoutConstraint.activate([
            fetchLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            fetchLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            actions.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            actions.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 260),
        ])
        return bar
    }

    // MARK: Binding

    private func bind() {
        viewModel.onRowsAppended = { [weak self] range in
            guard let self else { return }
            tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
            if range.lowerBound > 0 { tableView.reloadData(forRowIndexes: IndexSet(integer: range.lowerBound - 1), columnIndexes: IndexSet(integer: 0)) }
            updateGraphWidth()
        }
        viewModel.onMetadataChanged = { [weak self] in
            guard let self else { return }
            sidebar.reload(from: viewModel)
            reloadVisibleRows()
            updateFetchLabel()
            if selectedRow < 0, !viewModel.isLoading, let head = viewModel.headSHA, let index = viewModel.rowIndex(of: head) { select(row: index, scroll: false) }
            reportLoadedOnce()
        }
        viewModel.onStatusChanged = { [weak self] text in self?.statusLabel.stringValue = text }
    }

    private func updateGraphWidth() {
        let lanes = min(viewModel.maxLaneCount, Theme.Graph.maxVisibleLanes)
        let width = Theme.Graph.firstLane + CGFloat(lanes) * Theme.Graph.lane
        guard width != graphWidth else { return }
        graphWidth = width
        headerView.graphWidth = width
        reloadVisibleRows()
    }

    private func reloadVisibleRows() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.length > 0 else { return }
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)), columnIndexes: IndexSet(integer: 0))
    }

    private func updateFetchLabel() {
        let remote = viewModel.refs.contains { if case .remoteBranch = $0.kind { true } else { false } } ? "origin" : "kein Remote"
        guard let date = viewModel.lastFetch else {
            fetchLabel.stringValue = "\(remote) · noch nicht gefetcht"
            return
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        fetchLabel.stringValue = "\(remote) · gefetcht \(formatter.localizedString(for: date, relativeTo: Date()))"
        fetchLabel.toolTip = "Letzter Fetch: " + GraphRowView.exactFormatter.string(from: date)
    }

    // MARK: Actions

    @objc private func fetch(_ sender: Any?) {
        Task { await viewModel.fetch() }
    }

    @objc private func search(_ sender: NSSearchField) {
        let query = sender.stringValue.lowercased()
        guard !query.isEmpty else { return }
        let count = viewModel.commits.count
        let start = selectedRow + 1
        for offset in 0..<count {
            let index = (start + offset) % count
            let commit = viewModel.commits[index]
            if commit.subject.lowercased().contains(query) || commit.authorName.lowercased().contains(query) || commit.id.hasPrefix(query) {
                select(row: index, scroll: true)
                return
            }
        }
        NSSound.beep()
    }

    private func navigate(to sha: String) {
        guard let index = viewModel.rowIndex(of: sha) else { NSSound.beep(); return }
        select(row: index, scroll: true)
    }

    private func select(row: Int, scroll: Bool) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        if scroll {
            // Leave a few rows of context above the target.
            tableView.scrollRowToVisible(min(row + 6, viewModel.rows.count - 1))
            tableView.scrollRowToVisible(max(row - 3, 0))
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { viewModel.rows.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let previous = selectedRow
        selectedRow = tableView.selectedRow
        let changed = IndexSet([previous, selectedRow].filter { $0 >= 0 && $0 < viewModel.rows.count })
        tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        guard selectedRow >= 0 else { detail.showNothing(); return }
        if viewModel.kinds[selectedRow] == .wip, let status = viewModel.status {
            detail.showWorkingDirectory(status: status)
        } else {
            detail.show(commit: viewModel.commits[selectedRow], strand: Theme.strand(viewModel.rows[selectedRow].color), repository: viewModel.repository)
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        guard index < viewModel.rows.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("row")
        let view = (tableView.makeView(withIdentifier: identifier, owner: nil) as? GraphRowView) ?? GraphRowView()
        view.identifier = identifier
        let commit = viewModel.commits[index]
        let kind = viewModel.kinds[index]
        let refs = viewModel.refsByCommit[commit.id] ?? []
        let stash = viewModel.stashesByCommit[commit.id]
        var wipCounts: (changed: Int, staged: Int, untracked: Int)?
        if kind == .wip, let status = viewModel.status {
            let untracked = status.entries.filter(\.isUntracked).count
            wipCounts = (status.unstaged.count - untracked + status.conflicted.count, status.staged.count, untracked)
        }
        view.model = GraphRowView.Model(
            commit: commit,
            row: viewModel.rows[index],
            previous: index > 0 ? viewModel.rows[index - 1] : nil,
            next: index + 1 < viewModel.rows.count ? viewModel.rows[index + 1] : nil,
            kind: kind,
            previousKind: index > 0 ? viewModel.kinds[index - 1] : nil,
            pills: pills(for: refs),
            isHead: refs.contains(where: \.isHead),
            dimmed: kind != .stash && !viewModel.isReachableFromHead(commit.id),
            isSelected: index == selectedRow,
            subject: stash.map { "\($0.selector): \($0.message)" } ?? commit.subject,
            wipCounts: wipCounts,
            graphWidth: graphWidth
        )
        view.toolTip = kind == .wip ? "Uncommittete Änderungen" : GraphRowView.exactFormatter.string(from: commit.authorDate)
        return view
    }

    /// A local branch and its same-named remote branches share one label. The first glyph says where the branch stands: checked out here, checked out in another worktree, or just local.
    private func pills(for refs: [Ref]) -> [PillModel] {
        var order: [String] = []
        var local: [String: Ref] = [:]
        var remoteCount: [String: Int] = [:]
        var others: [PillModel] = []
        let elsewhere = viewModel.branchesInOtherWorktrees
        for ref in refs {
            switch ref.kind {
            case .localBranch:
                if local[ref.name] == nil, remoteCount[ref.name] == nil { order.append(ref.name) }
                local[ref.name] = ref
            case .remoteBranch(let remote):
                let base = String(ref.name.dropFirst(remote.count + 1))
                // `origin/HEAD` only points at the remote's default branch and carries no information of its own.
                if base == "HEAD" { continue }
                if local[base] == nil, remoteCount[base] == nil { order.append(base) }
                remoteCount[base, default: 0] += 1
            case .tag:
                others.append(PillModel(name: ref.name, glyphs: [.tag], isHead: false))
            case .stash:
                continue
            case .other:
                others.append(PillModel(name: ref.name, glyphs: [], isHead: false))
            }
        }
        let branches = order.map { name -> PillModel in
            var glyphs: [Glyph] = []
            if let ref = local[name] {
                if ref.isHead { glyphs += [.check, .laptop] }
                else if elsewhere[ref.fullName] != nil { glyphs.append(.bonsaiLinked) }
                else { glyphs.append(.laptop) }
            }
            glyphs += Array(repeating: Glyph.cloud, count: remoteCount[name] ?? 0)
            return PillModel(name: name, glyphs: glyphs, isHead: local[name]?.isHead ?? false)
        }
        // The pill list is drawn right to left, so the most important label comes first.
        return branches.sorted { $0.isHead && !$1.isHead } + others
    }

    private func reportLoadedOnce() {
        guard !didReportLoaded, !viewModel.isLoading else { return }
        didReportLoaded = true
        if ScreenshotHarness.outputPath != nil {
            if let row = ScreenshotHarness.selectRow, row < viewModel.rows.count { select(row: row, scroll: true) }
            if ProcessInfo.processInfo.environment["GITBONSAI_SCROLL_TO_STASH"] != nil, let row = viewModel.kinds.firstIndex(of: .stash) { select(row: row, scroll: true) }
        }
        onLoaded?()
    }
}
