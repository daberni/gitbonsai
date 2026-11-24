import AppKit
import GitEngine

/// The diff of one file, shown in the history pane in place of the graph. In the working directory each hunk can be staged or unstaged, and unstaged or untracked hunks discarded.
/// The "Whole file" mode shows the whole file with the changes in place instead; hunks are staged in the "Diff" mode only.
/// Embedded in `StackedDiffController` it shows one of several files: as tall as its content, scrolled by the stack around it.
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
    let scroll: NSScrollView
    let isEmbedded: Bool
    /// The embedded view's height, which follows its content.
    private var embeddedHeight: NSLayoutConstraint?
    /// Takes the place of the lines when there are none to show: binary files, pure renames, mode changes, no changes.
    let emptyState = EmptyStateView()
    /// Takes the place of the lines for a changed image.
    let imageView = ImageDiffView()
    /// Both sides of a changed image, or nil for any other file.
    var images: ImageDiffContent?
    var imageMode = ImageDiffMode.remembered
    /// Images over the automatic limit load once asked for, for the file shown.
    var loadsLargeImages = false
    let column = NSTableColumn(identifier: .init("diff"))
    /// The diff git applies hunks from, under the whitespace options.
    var diff: FileDiff?
    /// The same changes as a word diff, read in the "Diff" mode while that option is on.
    var words: FileDiff?
    /// The hunks whose lines are shown.
    var shown: FileDiff? { words ?? diff }
    var mode = DiffMode.remembered
    var style = DiffLineStyle(options: DiffOptions.remembered)
    /// Every line of the file, read only in the "Whole file" mode.
    var fileLines: [DiffLine] = []
    /// The rows hunk navigation stops at: hunk headers, or in the "Whole file" mode the line each hunk starts with.
    var hunkStarts: [Int] = []
    var rows: [Row] = []
    var loadTask: Task<Void, Never>?
    /// The read under way and what it does once it is in.
    var pending: PendingLoad?

    init(staging: StagingController, repository: @escaping () -> Repository, embedded: Bool = false) {
        self.staging = staging
        self.repository = repository
        isEmbedded = embedded
        scroll = embedded ? NestedScrollView() : NSScrollView()
        super.init()
        header.isEmbedded = embedded
        header.onClose = { [weak self] in self?.onClose?() }
        header.onModeChange = { [weak self] in self?.switchMode(to: $0) }
        header.onOptionsChange = { [weak self] in self?.changeOptions(to: $0) }
        header.onPrevious = { [weak self] in self?.jumpToHunk(forward: false) }
        header.onNext = { [weak self] in self?.jumpToHunk(forward: true) }
        header.onFileAction = { [weak self] in self?.runFileAction() }
        header.onImageModeChange = { [weak self] in self?.switchImageMode(to: $0) }
        imageView.onLoadLarge = { [weak self] in self?.loadLargeImages() }
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
        scroll.hasVerticalScroller = !isEmbedded
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface0
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled(_:)), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        emptyState.isHidden = true
        emptyState.onAction = { [weak self] in self?.retry() }
        imageView.isHidden = true
        for subview in [header, scroll, emptyState, imageView] as [NSView] {
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
            imageView.topAnchor.constraint(equalTo: header.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        if isEmbedded {
            embeddedHeight = view.heightAnchor.constraint(equalToConstant: Theme.Diff.headerHeight + Theme.Diff.stackedEmptyHeight)
            embeddedHeight?.isActive = true
        }
    }

    /// Room for every row, for the images, or for the empty state, plus a horizontal scroller that takes space.
    func fitEmbeddedHeight() {
        guard let embeddedHeight else { return }
        let lines = !imageView.isHidden ? Theme.Diff.stackedImageHeight : scroll.isHidden || rows.isEmpty ? Theme.Diff.stackedEmptyHeight : table.rect(ofRow: rows.count - 1).maxY
        let scroller = scroll.hasHorizontalScroller && NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        embeddedHeight.constant = Theme.Diff.headerHeight + lines + scroller
    }

    /// Hunk headers place their button by what is visible; a sideways scroll moves it along in every row the table keeps.
    @objc private func scrolled(_ notification: Notification) {
        table.enumerateAvailableRowViews { rowView, _ in (rowView.view(atColumn: 0) as? NSView)?.needsLayout = true }
    }

    // MARK: Actions

    private func runFileAction() {
        guard let selection, diff != nil else { return }
        if selection.isUnstageable { staging.unstage([selection.path]) } else { staging.stage([selection.path]) }
    }

    func runHunkAction(_ index: Int) {
        guard !style.options.changesHunks, let selection, let diff, diff.hunks.indices.contains(index) else { return }
        if selection.isUnstageable { staging.unstage(diff.hunks[index], of: diff) } else { staging.stage(diff.hunks[index], of: diff) }
    }

    func discardHunk(_ index: Int) {
        guard !style.options.changesHunks, let selection, selection.isStageable, let diff, diff.hunks.indices.contains(index) else { return }
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
    func scrollToTop(row: Int, resettingSideways: Bool = false) {
        guard let scroll = table.enclosingScrollView else { return }
        let x = resettingSideways ? 0 : scroll.contentView.bounds.minX
        scroll.contentView.scroll(to: NSPoint(x: x, y: offset(ofRow: row)))
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
        case .line(let hunk, let line): shown?.hunks[hunk].lines[line]
        case .fileLine(let index): fileLines[index]
        case .hunk(let index): shown?.hunks[index].lines.first
        case .notice: nil
        }
        return line.map { "\($0.oldNumber.map(String.init) ?? "-")/\($0.newNumber.map(String.init) ?? "-")" } ?? "none"
    }

    /// Hunks of a word diff or a diff without some whitespace do not match the file; staging or discarding them needs the plain diff.
    private var hunkBlockedReason: String? {
        guard style.options.changesHunks else { return nil }
        return String(localized: "diff.hunk.blockedByOptions", defaultValue: "Turn off Word Diff and the Ignore options to stage or discard single hunks. Whole files can still be staged.", bundle: .module, comment: "Tooltip of the disabled hunk buttons while the diff options change the hunks")
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
            if let shown { view.show(shown.hunks[index], actionTitle: title, canDiscard: selection?.isStageable == true, blockedReason: hunkBlockedReason) }
            view.onAction = { [weak self] in self?.runHunkAction(index) }
            view.onDiscard = { [weak self] in self?.discardHunk(index) }
            return view
        case .line(let hunk, let line):
            let view = (tableView.makeView(withIdentifier: .init("line"), owner: nil) as? DiffLineView) ?? DiffLineView()
            view.identifier = .init("line")
            if let shown { view.content = style.content(ofHunk: hunk, line: line, in: shown) }
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

/// The lines of one stacked file scroll sideways themselves; vertical scrolling belongs to the stack around them.
final class NestedScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        NSEvent.split(event, sideways: { super.scrollWheel(with: $0) }, vertical: { nextResponder?.scrollWheel(with: $0) })
    }
}

/// A diff being read for a file, and what happens once it is in.
struct PendingLoad {
    enum Scroll: Comparable {
        /// The same file read again stays where it is.
        case keep
        /// To the top, or in the "Whole file" mode to the first change; `sideways` also back to the left edge, for another file.
        case start(sideways: Bool)

        /// The stronger reset wins when two loads merge.
        private var strength: Int {
            switch self {
            case .keep: 0
            case .start(let sideways): sideways ? 2 : 1
            }
        }

        static func < (lhs: Scroll, rhs: Scroll) -> Bool { lhs.strength < rhs.strength }
    }

    let selection: FileSelection
    let scroll: Scroll
    /// Only a reload closes the diff once the file has no changes left; a new file shows "No changes" instead.
    let closesWhenGone: Bool
    let ready: [() -> Void]
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

extension DiffViewController {
    /// What the pane shows, for harness reports: the empty state's title and its action, or how many rows.
    var harnessState: String {
        guard emptyState.isHidden else { return "empty: \(emptyState.harnessSummary)" }
        return "\(rows.count) rows"
    }
}

