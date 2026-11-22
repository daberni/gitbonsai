import AppKit
import GitEngine

/// The diff of one file, shown in the history pane in place of the graph. In the working directory each hunk can be staged or unstaged, and unstaged or untracked hunks discarded.
/// The "Whole file" mode shows the whole file with the changes in place instead; hunks are staged in the "Diff" mode only.
@MainActor
final class DiffViewController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    enum Row {
        case hunk(Int)
        case line(hunk: Int, line: Int)
        /// A line of the whole file in the "Whole file" mode.
        case fileLine(Int)
        /// A sentence about the whole file above its lines.
        case notice(String)
    }

    let view = NSView()
    var onClose: (() -> Void)?
    var selection: FileSelection?

    private let staging: StagingController
    let repository: () -> Repository
    let header = DiffHeaderView()
    let table = NSTableView()
    let scroll = NSScrollView()
    /// Takes the place of the lines when there are none to show: binary files, pure renames, mode changes, no changes.
    let emptyState = EmptyStateView()
    let column = NSTableColumn(identifier: .init("diff"))
    var diff: FileDiff?
    var mode = DiffMode.remembered
    var style = DiffLineStyle(options: DiffOptions.remembered)
    /// Every line of the file, read only in the "Whole file" mode.
    var fileLines: [DiffLine] = []
    /// The rows hunk navigation stops at: hunk headers, or in the "Whole file" mode the line each hunk starts with.
    var hunkStarts: [Int] = []
    var rows: [Row] = []
    var loadTask: Task<Void, Never>?

    init(staging: StagingController, repository: @escaping () -> Repository) {
        self.staging = staging
        self.repository = repository
        super.init()
        header.onBack = { [weak self] in self?.onClose?() }
        header.onModeChange = { [weak self] in self?.switchMode(to: $0) }
        header.onOptionsChange = { [weak self] in self?.changeOptions(to: $0) }
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
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface0
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        emptyState.isHidden = true
        for subview in [header, scroll, emptyState] as [NSView] {
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
            emptyState.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// Hunk headers place their button by what is visible; a sideways scroll moves it along.
    @objc private func scrolled(_ notification: Notification) {
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<(visible.location + visible.length) {
            table.view(atColumn: 0, row: row, makeIfNecessary: false)?.needsLayout = true
        }
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

    func discardHunk(_ index: Int) {
        guard let selection, selection.isStageable, let diff, diff.hunks.indices.contains(index) else { return }
        staging.discard(diff.hunks[index], of: diff, untracked: selection.source == .untracked)
    }

    /// Near the end of the file several hunks can share one scroll position; a jump goes to the next hunk that actually moves the view, and beeps when none does.
    private func jumpToHunk(forward: Bool) {
        let top = topRow
        let current = clipView?.bounds.minY ?? 0
        let candidates = forward ? hunkStarts.filter { $0 > top } : hunkStarts.filter { $0 < top }.reversed()
        let target = candidates.first { forward ? offset(ofRow: $0) > current : offset(ofRow: $0) < current }
        guard let target else { NSSound.beep(); return }
        scrollToTop(row: target)
    }

    /// The first row in view; harness checks read it after a jump.
    var topRow: Int { table.rows(in: table.visibleRect).location }

    private var clipView: NSClipView? { table.enclosingScrollView?.contentView }

    /// Where a hunk starts goes to the top of the view, unless that would show empty space below the last line: then the last line sits at the bottom.
    func scrollToTop(row: Int) {
        guard let scroll = table.enclosingScrollView else { return }
        scroll.contentView.scroll(to: NSPoint(x: scroll.contentView.bounds.minX, y: offset(ofRow: row)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The vertical scroll offset that brings a row to the top, clamped to the document. `NSClipView.scroll(to:)` takes any point as given.
    private func offset(ofRow row: Int) -> CGFloat {
        guard let clipView, rows.indices.contains(row) else { return 0 }
        let lastOffset = max(0, table.frame.height - clipView.bounds.height)
        return min(max(0, table.rect(ofRow: row).minY), lastOffset)
    }

    /// The old and new number of the first row in view, as the gutter shows them.
    var topLineNumbers: String { lineNumbers(ofRow: topRow) }

    /// The numbers of the last row in view, and whether it is the last row and ends at the bottom of the view; harness checks read them.
    var bottomLineNumbers: String {
        guard let clipView else { return "none" }
        let visible = clipView.bounds
        let bottom = table.row(at: NSPoint(x: visible.minX, y: visible.maxY - 1))
        let isLast = bottom == rows.count - 1 && abs(table.rect(ofRow: bottom).maxY - visible.maxY) < 1
        return "\(lineNumbers(ofRow: bottom))\(isLast ? " (last line at bottom)" : "")"
    }

    private func lineNumbers(ofRow row: Int) -> String {
        guard rows.indices.contains(row) else { return "none" }
        let line: DiffLine? = switch rows[row] {
        case .line(let hunk, let line): diff?.hunks[hunk].lines[line]
        case .fileLine(let index): fileLines[index]
        case .hunk(let index): diff?.hunks[index].lines.first
        case .notice: nil
        }
        return line.map { "\($0.oldNumber.map(String.init) ?? "-")/\($0.newNumber.map(String.init) ?? "-")" } ?? "none"
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .line, .fileLine: Theme.Diff.lineHeight
        case .hunk: Theme.Diff.hunkHeight
        case .notice: Theme.Diff.noticeHeight
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .hunk(let index):
            let view = (tableView.makeView(withIdentifier: .init("hunk"), owner: nil) as? DiffHunkView) ?? DiffHunkView()
            view.identifier = .init("hunk")
            let title: String? = selection?.isUnstageable == true ? String(localized: "diff.hunk.unstage", defaultValue: "Unstage Hunk", bundle: .module) : selection?.isStageable == true ? String(localized: "diff.hunk.stage", defaultValue: "Stage Hunk", bundle: .module) : nil
            if let diff { view.show(diff.hunks[index], actionTitle: title, canDiscard: selection?.isStageable == true) }
            view.onAction = { [weak self] in self?.runHunkAction(index) }
            view.onDiscard = { [weak self] in self?.discardHunk(index) }
            return view
        case .line(let hunk, let line):
            let view = (tableView.makeView(withIdentifier: .init("line"), owner: nil) as? DiffLineView) ?? DiffLineView()
            view.identifier = .init("line")
            if let diff { view.content = style.content(ofHunk: hunk, line: line, in: diff) }
            return view
        case .fileLine(let index):
            let view = (tableView.makeView(withIdentifier: .init("line"), owner: nil) as? DiffLineView) ?? DiffLineView()
            view.identifier = .init("line")
            view.content = style.content(ofFileLine: index, in: fileLines)
            return view
        case .notice(let text):
            let view = (tableView.makeView(withIdentifier: .init("notice"), owner: nil) as? DiffNoticeView) ?? DiffNoticeView()
            view.identifier = .init("notice")
            view.text = text
            return view
        }
    }
}

/// A line's place on both sides of the comparison; nil on the side it does not exist.
struct NumberPair: Hashable {
    let old: Int?
    let new: Int?

    init(_ line: DiffLine) {
        old = line.oldNumber
        new = line.newNumber
    }
}
