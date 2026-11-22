import AppKit
import GitEngine

/// The diff of one file, shown in the history pane in place of the graph. In the working directory each hunk can be staged or unstaged.
@MainActor
final class DiffViewController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case hunk(Int)
        case line(hunk: Int, line: Int)
        case message(String)
    }

    let view = NSView()
    var onClose: (() -> Void)?
    private(set) var selection: FileSelection?

    private let staging: StagingController
    private let repository: () -> Repository
    private let header = DiffHeaderView()
    private let table = NSTableView()
    private let column = NSTableColumn(identifier: .init("diff"))
    private var diff: FileDiff?
    private var rows: [Row] = []
    private var loadTask: Task<Void, Never>?

    init(staging: StagingController, repository: @escaping () -> Repository) {
        self.staging = staging
        self.repository = repository
        super.init()
        header.onBack = { [weak self] in self?.onClose?() }
        header.onPrevious = { [weak self] in self?.jumpToHunk(forward: false) }
        header.onNext = { [weak self] in self?.jumpToHunk(forward: true) }
        header.onFileAction = { [weak self] in self?.runFileAction() }
        configureTable()
        layout()
    }

    private func configureTable() {
        table.dataSource = self
        table.delegate = self
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.backgroundColor = Theme.surface0
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
    }

    private func layout() {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface0
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        for subview in [header, scroll] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: Theme.Diff.headerHeight),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Hunk headers place their button by what is visible; a sideways scroll moves it along.
    @objc private func scrolled(_ notification: Notification) {
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            table.view(atColumn: 0, row: row, makeIfNecessary: false)?.needsLayout = true
        }
    }

    // MARK: Loading

    /// Reads the file's diff and only then replaces what is shown, so the previous diff never flashes up. `ready` runs once the new one is in place.
    func show(_ selection: FileSelection, ready: (() -> Void)? = nil) {
        let isNewFile = selection != self.selection
        loadTask?.cancel()
        let repository = repository()
        loadTask = Task { [weak self] in
            let diff = try? await repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source)
            guard let self, !Task.isCancelled else { return }
            self.selection = selection
            apply(diff, scrollToTop: isNewFile)
            ready?()
        }
    }

    /// After the index changed: the same file, read again. Once it has no changes left on the side shown, the diff closes.
    func reload() {
        guard let selection else { return }
        let repository = repository()
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let diff = try? await repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source)
            guard let self, !Task.isCancelled else { return }
            guard diff != nil else {
                onClose?()
                return
            }
            apply(diff, scrollToTop: false)
        }
    }

    private func apply(_ diff: FileDiff?, scrollToTop: Bool) {
        guard let selection else { return }
        self.diff = diff
        header.show(selection, diff: diff)
        rows = []
        if let diff, diff.isBinary {
            rows = [.message("Binärdatei, kein Textvergleich.")]
        } else if let diff, !diff.hunks.isEmpty {
            for (hunkIndex, hunk) in diff.hunks.enumerated() {
                rows.append(.hunk(hunkIndex))
                rows += hunk.lines.indices.map { .line(hunk: hunkIndex, line: $0) }
            }
        } else {
            rows = [.message("Keine Änderungen.")]
        }
        column.minWidth = contentWidth()
        table.reloadData()
        if scrollToTop { table.scrollRowToVisible(0) }
    }

    /// Wide enough for the longest line, so long lines scroll sideways instead of being cut.
    private func contentWidth() -> CGFloat {
        let longest = diff?.hunks.flatMap(\.lines).map { DiffLineView.display($0.text).count }.max() ?? 0
        let characterWidth = NSAttributedString(string: "0", attributes: [.font: Theme.mono]).size().width
        return DiffLineView.textX + CGFloat(longest) * characterWidth + Theme.Space.xl
    }

    // MARK: Actions

    private func runFileAction() {
        guard let selection, diff != nil else { return }
        if selection.isUnstageable { staging.unstage([selection.path]) } else { staging.stage([selection.path]) }
    }

    func runHunkAction(_ index: Int) {
        guard let selection, let diff, diff.hunks.indices.contains(index) else { return }
        if selection.isUnstageable { staging.unstage(diff.hunks[index], of: diff) } else { staging.stage(diff.hunks[index], of: diff) }
    }

    private func jumpToHunk(forward: Bool) {
        let hunkRows = rows.indices.filter { if case .hunk = rows[$0] { true } else { false } }
        let top = table.rows(in: table.visibleRect).location
        let target = forward ? hunkRows.first { $0 > top } : hunkRows.last { $0 < top }
        guard let target else { NSSound.beep(); return }
        // The hunk header goes to the top of the view.
        if let scroll = table.enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: table.rect(ofRow: target).minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .line = rows[row] { return Theme.Diff.lineHeight }
        return Theme.Diff.hunkHeight
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .hunk(let index):
            let view = (tableView.makeView(withIdentifier: .init("hunk"), owner: nil) as? DiffHunkView) ?? DiffHunkView()
            view.identifier = .init("hunk")
            let title: String? = selection?.isUnstageable == true ? "Hunk unstagen" : selection?.isStageable == true ? "Hunk stagen" : nil
            if let diff { view.show(diff.hunks[index], actionTitle: title) }
            view.onAction = { [weak self] in self?.runHunkAction(index) }
            return view
        case .line(let hunk, let line):
            let view = (tableView.makeView(withIdentifier: .init("line"), owner: nil) as? DiffLineView) ?? DiffLineView()
            view.identifier = .init("line")
            view.line = diff?.hunks[hunk].lines[line]
            return view
        case .message(let text):
            let field = NSTextField(labelWithString: text)
            field.font = Theme.body
            field.textColor = Theme.inkMuted
            return field
        }
    }
}
