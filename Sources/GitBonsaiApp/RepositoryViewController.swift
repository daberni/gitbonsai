import AppKit
import GitEngine
import GraphLayout

/// The content of one repository tab: toolbar row, then sidebar, history and detail panel side by side, then the status line.
@MainActor
final class RepositoryViewController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    /// The worktree this tab shows; changes when the tab moves to another worktree.
    var repositoryPath: String { viewModel.repository.path }
    let view: NSView = FillView(color: Theme.surface1)
    /// Called once, when the first full load has finished and the initial selection is set.
    var onLoaded: (() -> Void)?
    /// A worktree was chosen. The window decides whether this tab moves there or another tab already shows it.
    var onSwitchWorktree: ((String) -> Void)?
    /// The repository name became known or changed.
    var onNameChanged: (() -> Void)?
    var name: String { viewModel.repositoryName }
    var preferredFirstResponder: NSView { tableView }

    private let viewModel: GraphViewModel
    private let tableView = HistoryTableView()
    private let headerView = HistoryHeaderView()
    private let columnGuide = ColumnGuideView()
    private let sidebar = SidebarView()
    private let detail = DetailView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let fetchLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private var columns = ColumnStore.load()
    /// Nil while the graph column follows the number of lanes; set once the user has dragged it.
    private var chosenGraphWidth = ColumnStore.loadGraphWidth()
    private var selectedRow = -1
    private var didReportLoaded = false
    private var lastReportedName = ""

    init(repositoryPath: String) {
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
        sidebar.onCheckout = { [weak self] target, worktreePath in
            // A branch can be checked out only once; if another worktree has it, going there is the checkout.
            if let worktreePath { self?.onSwitchWorktree?(worktreePath) } else { self?.checkout(target) }
        }
        sidebar.onSwitchWorktree = { [weak self] path in self?.onSwitchWorktree?(path) }

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = Theme.Graph.rowHeight
        tableView.headerView = nil
        tableView.style = .plain
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = Theme.surface0
        tableView.selectionHighlightStyle = .none
        tableView.gridStyleMask = []
        tableView.target = self
        tableView.onGraphScroll = { [weak self] deltaX, point in self?.scrollGraph(by: deltaX, at: point) ?? false }
        headerView.columns = columns
        tableView.columns = columns
        let resetGraph: () -> Void = { [weak self] in
            guard let self else { return }
            chosenGraphWidth = nil
            updateGraphWidth()
            ColumnStore.save(columns, graphWidth: nil)
        }
        headerView.onDrag = { [weak self] divider, x in self?.resize(divider, to: x) }
        headerView.onResetGraph = resetGraph
        headerView.makeMenu = { [weak self] in self?.columnMenu() ?? NSMenu() }
        columnGuide.columns = columns
        tableView.onDrag = { [weak self] divider, x in self?.resize(divider, to: x) }
        tableView.onResetGraph = resetGraph
        tableView.doubleAction = #selector(checkoutClickedRow(_:))
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        let column = NSTableColumn(identifier: .init("history"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let historyScroll = scroll(tableView, background: Theme.surface0)
        let history = NSView()
        headerView.translatesAutoresizingMaskIntoConstraints = false
        history.addSubview(headerView)
        history.addSubview(historyScroll)
        columnGuide.translatesAutoresizingMaskIntoConstraints = false
        history.addSubview(columnGuide)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: history.topAnchor),
            headerView.leadingAnchor.constraint(equalTo: history.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: history.trailingAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 30),
            historyScroll.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            historyScroll.leadingAnchor.constraint(equalTo: history.leadingAnchor),
            historyScroll.trailingAnchor.constraint(equalTo: history.trailingAnchor),
            historyScroll.bottomAnchor.constraint(equalTo: history.bottomAnchor),
            columnGuide.topAnchor.constraint(equalTo: history.topAnchor),
            columnGuide.leadingAnchor.constraint(equalTo: history.leadingAnchor),
            columnGuide.trailingAnchor.constraint(equalTo: history.trailingAnchor),
            columnGuide.bottomAnchor.constraint(equalTo: history.bottomAnchor),
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
        viewModel.onReset = { [weak self] in
            guard let self else { return }
            selectedRow = -1
            tableView.reloadData()
            detail.showNothing()
        }
        viewModel.onRowsShifted = { [weak self] in
            self?.tableView.reloadData()
            self?.updateGraphWidth()
        }
        viewModel.onRowsRebuilt = { [weak self] in
            guard let self else { return }
            // Same commits, new HEAD: the selection follows the working tree and the newly checked-out commit is brought into view.
            selectedRow = -1
            tableView.deselectAll(nil)
            tableView.reloadData()
            updateGraphWidth()
            selectCurrentRow(scrollToHead: true)
        }
        viewModel.onMetadataChanged = { [weak self] in
            guard let self else { return }
            if name != lastReportedName {
                lastReportedName = name
                onNameChanged?()
            }
            sidebar.reload(from: viewModel)
            reloadVisibleRows()
            updateFetchLabel()
            if selectedRow < 0, !viewModel.isLoading { selectCurrentRow(scrollToHead: false) }
            reportLoadedOnce()
        }
        viewModel.onStatusChanged = { [weak self] text in self?.statusLabel.stringValue = text }
    }

    /// Width the graph needs to show every lane.
    private var graphContentWidth: CGFloat {
        Theme.Graph.firstLane + CGFloat(viewModel.maxLaneCount) * Theme.Graph.lane
    }

    /// Fits the graph column to the lanes unless the user chose a width, and keeps the scroll position inside the graph.
    private func updateGraphWidth() {
        var updated = columns
        let automatic = Theme.Graph.firstLane + CGFloat(min(viewModel.maxLaneCount, Theme.Graph.maxVisibleLanes)) * Theme.Graph.lane
        updated.graph = chosenGraphWidth ?? automatic
        updated.graphScrollX = min(max(updated.graphScrollX, 0), max(graphContentWidth - updated.graph, 0))
        headerView.graphContentWidth = graphContentWidth
        apply(updated)
    }

    private func apply(_ updated: HistoryColumns) {
        guard updated != columns else { return }
        columns = updated
        headerView.columns = updated
        tableView.columns = updated
        columnGuide.columns = updated
        reloadVisibleRows()
    }

    /// A column boundary was dragged to `x`, in the history's coordinates.
    private func resize(_ column: HistoryColumns.Column, to x: CGFloat) {
        var updated = columns
        updated.drag(column, to: x, in: headerView.bounds.width)
        if column == .graph {
            chosenGraphWidth = updated.graph
            updated.graphScrollX = min(updated.graphScrollX, max(graphContentWidth - updated.graph, 0))
        }
        apply(updated)
        ColumnStore.save(columns, graphWidth: chosenGraphWidth)
    }

    // MARK: Column menu

    private func columnMenu() -> NSMenu {
        let menu = NSMenu()
        for column in HistoryColumns.Column.allCases {
            let item = NSMenuItem(title: column.title, action: column == .commit ? nil : #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = column.rawValue
            item.state = columns.shows(column) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let automatic = NSMenuItem(title: "Graph-Breite automatisch", action: #selector(toggleAutomaticGraphWidth(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = chosenGraphWidth == nil ? .on : .off
        menu.addItem(automatic)
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Spalten zurücksetzen", action: #selector(resetColumns(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        return menu
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = HistoryColumns.Column(rawValue: raw) else { return }
        var updated = columns
        if updated.hidden.remove(column) == nil { updated.hidden.insert(column) }
        apply(updated)
        ColumnStore.save(columns, graphWidth: chosenGraphWidth)
    }

    @objc private func toggleAutomaticGraphWidth(_ sender: Any?) {
        chosenGraphWidth = chosenGraphWidth == nil ? columns.graph : nil
        updateGraphWidth()
        ColumnStore.save(columns, graphWidth: chosenGraphWidth)
    }

    @objc private func resetColumns(_ sender: Any?) {
        chosenGraphWidth = nil
        var updated = HistoryColumns.standard
        updated.graphScrollX = columns.graphScrollX
        apply(updated)
        updateGraphWidth()
        ColumnStore.save(columns, graphWidth: nil)
    }

    private func scrollGraph(by deltaX: CGFloat, at point: NSPoint) -> Bool {
        guard let graph = columns.layout(in: tableView.bounds.width).graph, graph.contains(point.x) else { return false }
        var updated = columns
        updated.graphScrollX = min(max(columns.graphScrollX - deltaX, 0), max(graphContentWidth - columns.graph, 0))
        apply(updated)
        return true
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

    // MARK: Checkout

    /// What a double click or the context menu offers on a history row: its branches first, the bare commit last.
    private func checkoutChoices(forRow index: Int) -> [(title: String, target: CheckoutTarget, worktreePath: String?)] {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .commit || viewModel.kinds[index] == .merge else { return [] }
        let commit = viewModel.commits[index]
        let refs = viewModel.refsByCommit[commit.id] ?? []
        let elsewhere = viewModel.branchesInOtherWorktrees
        var choices: [(title: String, target: CheckoutTarget, worktreePath: String?)] = []
        var localNames: Set<String> = []
        for ref in refs where ref.kind == .localBranch && !ref.isHead {
            localNames.insert(ref.name)
            let worktree = elsewhere[ref.fullName]
            let title = worktree.map { "Zu Worktree „\(($0.path as NSString).lastPathComponent)“ wechseln (\(ref.name))" } ?? "„\(ref.name)“ auschecken"
            choices.append((title, .localBranch(ref.name), worktree?.path))
        }
        for ref in refs {
            guard case .remoteBranch(let remote) = ref.kind, !ref.name.hasSuffix("/HEAD") else { continue }
            let branch = String(ref.name.dropFirst(remote.count + 1))
            let hasLocalHere = localNames.contains(branch) || refs.contains { $0.kind == .localBranch && $0.name == branch }
            if !hasLocalHere { choices.append(("„\(ref.name)“ als lokalen Branch auschecken", .remoteBranch(remote: remote, branch: branch), nil)) }
        }
        if commit.id != viewModel.headSHA || viewModel.currentBranch != nil {
            choices.append(("Commit \(commit.id.prefix(7)) auschecken (Detached HEAD)", .commit(commit.id), nil))
        }
        return choices
    }

    /// A double click checks out the branch at the row. A row without a branch does nothing: a detached HEAD should be asked for, not happen by accident.
    @objc private func checkoutClickedRow(_ sender: Any?) {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : selectedRow
        guard let choice = checkoutChoices(forRow: index).first, choice.target != .commit(viewModel.commits[index].id) else { return }
        perform(choice.target, worktreePath: choice.worktreePath)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (offset, choice) in checkoutChoices(forRow: tableView.clickedRow).enumerated() {
            if case .commit = choice.target, offset > 0 { menu.addItem(.separator()) }
            let item = NSMenuItem(title: choice.title, action: #selector(checkoutFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = offset
            menu.addItem(item)
        }
    }

    @objc private func checkoutFromMenu(_ sender: NSMenuItem) {
        let choices = checkoutChoices(forRow: tableView.clickedRow)
        guard let offset = sender.representedObject as? Int, choices.indices.contains(offset) else { return }
        perform(choices[offset].target, worktreePath: choices[offset].worktreePath)
    }

    private func perform(_ target: CheckoutTarget, worktreePath: String?) {
        if let worktreePath { onSwitchWorktree?(worktreePath) } else { checkout(target) }
    }

    func checkout(_ target: CheckoutTarget, carryingChanges: Bool = false) {
        Task {
            switch await viewModel.checkout(target, carryingChanges: carryingChanges) {
            case .done:
                break
            case .blockedByLocalChanges(let message):
                let alert = NSAlert()
                alert.messageText = "Lokale Änderungen stehen dem Wechsel im Weg"
                alert.informativeText = message
                alert.addButton(withTitle: "Stashen und wechseln")
                alert.addButton(withTitle: "Abbrechen")
                present(alert) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.checkout(target, carryingChanges: true) }
                }
            case .failed(let message):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Wechsel fehlgeschlagen"
                alert.informativeText = message
                present(alert) { _ in }
            }
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard ScreenshotHarness.outputPath == nil, let window = view.window else {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            return
        }
        alert.beginSheetModal(for: window) { response in completion(response) }
    }

    func switchWorktree(to path: String) {
        viewModel.switchWorktree(to: path)
    }

    private func navigate(to sha: String) {
        guard let index = viewModel.rowIndex(of: sha) else { NSSound.beep(); return }
        select(row: index, scroll: true)
    }

    /// Selects the uncommitted changes when there are any, otherwise HEAD. The changes sit in the first row, so HEAD is scrolled to separately.
    private func selectCurrentRow(scrollToHead: Bool) {
        guard let row = viewModel.currentRow else { return }
        select(row: row, scroll: false)
        guard scrollToHead, let head = viewModel.headSHA, let headRow = viewModel.rowIndex(of: head) else { return }
        tableView.scrollRowToVisible(min(headRow + 6, viewModel.rows.count - 1))
        tableView.scrollRowToVisible(max(headRow - 3, 0))
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
            wipLaneAbove: viewModel.wipStrand.flatMap { index >= 1 && index <= $0.headRow ? $0.lane : nil },
            wipLaneBelow: viewModel.wipStrand.flatMap { index < $0.headRow ? $0.lane : nil },
            pills: pills(for: refs),
            isHead: refs.contains(where: \.isHead),
            dimmed: kind != .stash && !viewModel.isReachableFromHead(commit.id),
            isSelected: index == selectedRow,
            subject: stash.map { "\($0.selector): \($0.message)" } ?? commit.subject,
            wipCounts: wipCounts,
            columns: columns
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
        if ScreenshotHarness.outputPath != nil, runHarnessAction() { return }
        if ScreenshotHarness.outputPath != nil {
            if let row = ScreenshotHarness.selectRow, row < viewModel.rows.count { select(row: row, scroll: true) }
            let environment = ProcessInfo.processInfo.environment
            if let width = environment["GITBONSAI_GRAPH_WIDTH"].flatMap(Double.init), let graph = columns.layout(in: tableView.bounds.width).graph { resize(.graph, to: graph.lowerBound + CGFloat(width)) }
            // A real drag through the window, starting on the boundary between graph and commit in the middle of the rows.
            if let target = environment["GITBONSAI_DRAG_GRAPH_TO"].flatMap(Double.init), let window = view.window {
                let y = tableView.visibleRect.midY
                func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: tableView.convert(NSPoint(x: x, y: y), to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                let graph = columns.layout(in: tableView.bounds.width).graph ?? 0...0
                let end = graph.lowerBound + CGFloat(target)
                if let drag = event(.leftMouseDragged, x: end), let up = event(.leftMouseUp, x: end), let down = event(.leftMouseDown, x: graph.upperBound) {
                    NSApp.postEvent(drag, atStart: false)
                    NSApp.postEvent(up, atStart: false)
                    window.sendEvent(down)
                }
                FileHandle.standardError.write(Data("graph column after drag: \(columns.graph)\n".utf8))
            }
            if let offset = environment["GITBONSAI_GRAPH_SCROLL"].flatMap(Double.init) { _ = scrollGraph(by: -CGFloat(offset), at: NSPoint(x: (columns.layout(in: tableView.bounds.width).graph?.lowerBound ?? 0) + 1, y: 1)) }
            if ProcessInfo.processInfo.environment["GITBONSAI_SCROLL_TO_STASH"] != nil, let row = viewModel.kinds.firstIndex(of: .stash) { select(row: row, scroll: true) }
        }
        onLoaded?()
    }

    /// `GITBONSAI_CHECKOUT=<branch>` checks a local branch out and `GITBONSAI_SWITCH_WORKTREE=<folder name>` switches the tab, each once, before the capture.
    private func runHarnessAction() -> Bool {
        guard !Self.didRunHarnessAction else { return false }
        let environment = ProcessInfo.processInfo.environment
        if let branch = environment["GITBONSAI_CHECKOUT"] {
            Self.didRunHarnessAction = true
            didReportLoaded = false
            checkout(.localBranch(branch))
            return true
        }
        if let folder = environment["GITBONSAI_SWITCH_WORKTREE"], let info = viewModel.worktrees.first(where: { $0.worktree.path == folder || ($0.worktree.path as NSString).lastPathComponent == folder }) {
            Self.didRunHarnessAction = true
            didReportLoaded = false
            onSwitchWorktree?(info.worktree.path)
            return true
        }
        return false
    }

    private static var didRunHarnessAction = false
}

/// Column widths and visibility are a preference of the user, shared by all tabs and kept across launches. Screenshot runs neither read nor write them.
@MainActor
enum ColumnStore {
    private static var defaults: UserDefaults? { ScreenshotHarness.outputPath == nil ? .standard : nil }

    static func load() -> HistoryColumns {
        var columns = HistoryColumns.standard
        if let hidden = ProcessInfo.processInfo.environment["GITBONSAI_HIDDEN_COLUMNS"] {
            columns.hidden = Set(hidden.split(separator: ",").compactMap { HistoryColumns.Column(rawValue: String($0)) })
        }
        guard let defaults else { return columns }
        func width(_ key: String) -> CGFloat? { defaults.object(forKey: key) == nil ? nil : CGFloat(defaults.double(forKey: key)) }
        columns.label = width("columnLabel") ?? columns.label
        columns.author = width("columnAuthor") ?? columns.author
        columns.sha = width("columnSHA") ?? columns.sha
        columns.date = width("columnDate") ?? columns.date
        if let hidden = defaults.stringArray(forKey: "hiddenColumns") { columns.hidden = Set(hidden.compactMap(HistoryColumns.Column.init(rawValue:))) }
        return columns
    }

    static func loadGraphWidth() -> CGFloat? {
        guard let defaults, defaults.object(forKey: "columnGraph") != nil else { return nil }
        return CGFloat(defaults.double(forKey: "columnGraph"))
    }

    static func save(_ columns: HistoryColumns, graphWidth: CGFloat?) {
        guard let defaults else { return }
        defaults.set(Double(columns.label), forKey: "columnLabel")
        defaults.set(Double(columns.author), forKey: "columnAuthor")
        defaults.set(Double(columns.sha), forKey: "columnSHA")
        defaults.set(Double(columns.date), forKey: "columnDate")
        defaults.set(columns.hidden.map(\.rawValue).sorted(), forKey: "hiddenColumns")
        if let graphWidth { defaults.set(Double(graphWidth), forKey: "columnGraph") } else { defaults.removeObject(forKey: "columnGraph") }
    }
}
