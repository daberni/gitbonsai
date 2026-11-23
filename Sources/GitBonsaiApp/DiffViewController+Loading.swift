import AppKit
import GitEngine

/// Reads the diff or the whole file of the shown selection and lays out its lines.
extension DiffViewController {
    // MARK: Loading

    /// Reads the file's diff and only then replaces what is shown, so the previous diff never flashes up. `ready` runs once the new one is in place.
    /// Another file starts at the top left; the same file again keeps its place.
    func show(_ selection: FileSelection, ready: (() -> Void)? = nil) {
        let isNewFile = selection != (pending?.selection ?? self.selection)
        if isNewFile { loadsLargeImages = false }
        load(selection, scroll: isNewFile ? .start(sideways: true) : .keep, closesWhenGone: false, ready: ready)
    }

    /// The history moved on: a diff still loading must not appear, and a later reload has nothing to read again.
    func close() {
        loadTask?.cancel()
        pending = nil
        selection = nil
    }

    /// After the index changed: the same file, read again. Once it has no changes left on the side shown, the diff closes; a read that failed keeps what is shown.
    func reload() {
        guard let selection = pending?.selection ?? selection else { return }
        load(selection, scroll: .keep, closesWhenGone: true)
    }

    /// The new mode holds for this file right away and for every file after it.
    func switchMode(to newMode: DiffMode) {
        guard newMode != mode, let selection = pending?.selection ?? selection else { return }
        mode = newMode
        DiffMode.remembered = newMode
        load(selection, scroll: .start(sideways: false), closesWhenGone: false)
    }

    /// Every read goes through here. A load that replaces one still pending keeps what that one promised: its scroll reset, its `ready` and that it shows the file even without changes.
    func load(_ selection: FileSelection, scroll: PendingLoad.Scroll, closesWhenGone: Bool, ready: (() -> Void)? = nil) {
        loadTask?.cancel()
        let previous = pending?.selection == selection ? pending : nil
        let load = PendingLoad(selection: selection, scroll: max(scroll, previous?.scroll ?? .keep), closesWhenGone: previous.map { $0.closesWhenGone && closesWhenGone } ?? closesWhenGone, ready: (previous?.ready ?? []) + (ready.map { [$0] } ?? []))
        pending = load
        let repository = self.repository()
        let mode = mode
        let options = style.options
        let loadsLargeImages = loadsLargeImages
        loadTask = Task { [weak self] in
            let read = try? await Self.read(selection, mode: mode, options: options, loadingLargeImages: loadsLargeImages, from: repository)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            if load.closesWhenGone {
                // A failed read, such as a lock held for a moment, says nothing about the file; only a diff that is gone closes the view.
                guard let read else { return }
                guard read.diff != nil else { onClose?(); return }
            }
            self.selection = selection
            images = read?.images
            words = read?.words
            apply(read?.diff, full: read?.full, encoding: read?.encoding, onlyLeftOut: read?.onlyLeftOut ?? false, scrolling: load.scroll)
            load.ready.forEach { $0() }
        }
    }

    private struct Read {
        var diff: FileDiff?
        var full: FileDiff?
        var words: FileDiff?
        var encoding: WideTextEncoding?
        var images: ImageDiffContent?
        /// The file changed, but only in what the whitespace options leave out; `diff` then has the file without hunks.
        var onlyLeftOut = false
    }

    /// The diff, and in the "Whole file" mode also the whole file; all are read before any is shown. A binary file is checked for UTF-16 text.
    /// A changed image also reads both of its sides. Under the options the word diff is read beside the diff, whose hunks the actions apply; in the "Whole file" mode the whole file is the word diff.
    private static func read(_ selection: FileSelection, mode: DiffMode, options: DiffOptions, loadingLargeImages: Bool, from repository: Repository) async throws -> Read {
        let whitespace = options.whitespace
        async let diff = repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source, whitespace: whitespace)
        async let full = mode == .file ? repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source, fullFile: true, whitespace: whitespace, words: options.wordDiff) : nil
        async let words = mode == .diff && options.wordDiff ? repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source, whitespace: whitespace, words: true) : nil
        let (readDiff, readFull, readWords) = try await (diff, full, words)
        guard let readDiff else {
            // git prints nothing for a file whose every change is left out; the plain diff tells it from a file without changes.
            guard whitespace.isFiltering, let plain = try await repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source) else { return Read() }
            let withoutHunks = FileDiff(path: plain.path, oldPath: plain.oldPath, isCopy: plain.isCopy, similarity: plain.similarity, isNew: plain.isNew, isDeleted: plain.isDeleted, isBinary: plain.isBinary, oldMode: plain.oldMode, newMode: plain.newMode, hunks: [], rawHeader: Data())
            return Read(diff: withoutHunks, onlyLeftOut: true)
        }
        var read = Read(diff: readDiff, full: readFull, words: readWords)
        read.images = await ImageDiffLoader.load(readDiff, path: selection.path, source: selection.source, from: repository, loadingLarge: loadingLargeImages)
        if case .images = read.images { return read }
        if readDiff.isBinary { read.encoding = await repository.wideTextEncoding(of: readDiff, in: selection.source) }
        return read
    }

    /// Invisibles change how the lines are drawn; word diff and whitespace read the file again.
    func changeOptions(to newOptions: DiffOptions) {
        guard newOptions != style.options else { return }
        let readsAgain = newOptions.readsDifferently(from: style.options)
        style.options = newOptions
        DiffOptions.remembered = newOptions
        if readsAgain, let selection = pending?.selection ?? selection {
            load(selection, scroll: .keep, closesWhenGone: false)
            return
        }
        column.minWidth = contentWidth()
        table.reloadData()
    }

    private func apply(_ diff: FileDiff?, full: FileDiff?, encoding: WideTextEncoding?, onlyLeftOut: Bool, scrolling: PendingLoad.Scroll) {
        guard let selection else { return }
        self.diff = diff
        fileLines = full?.hunks.flatMap(\.lines) ?? []
        header.show(selection, diff: diff, mode: mode, options: style.options)
        style.prepare(diff: shown, fileLines: fileLines)
        rows = imageNotice.map { [.notice($0)] } ?? []
        rows += style.notice.map { [.notice($0)] } ?? []
        hunkStarts = []
        let showsImages = applyImages()
        let empty = showsImages ? nil : onlyLeftOut ? Self.leftOutContent(style.options.whitespace) : Self.emptyContent(for: diff, encoding: encoding)
        if let empty { emptyState.show(empty) }
        emptyState.isHidden = empty == nil
        scroll.isHidden = empty != nil || showsImages
        if let diff, empty == nil, mode == .file, !fileLines.isEmpty {
            let firstLineRow = rows.count
            rows += fileLines.indices.map { .fileLine($0) }
            // A hunk starts with the same line in both views, and a line's pair of old and new number occurs once in the file.
            if style.options.wordDiff {
                // Word diff numbers follow the lines as shown, not the line diff's; navigation stops at each run of changed lines instead.
                let changed = fileLines.map { $0.kind != .context || !$0.segments.isEmpty }
                hunkStarts = changed.indices.filter { changed[$0] && ($0 == 0 || !changed[$0 - 1]) }.map { firstLineRow + max(0, $0 - Self.contextAboveChange) }
            } else {
                let rowOfNumbers = Dictionary(fileLines.enumerated().map { (NumberPair($1), firstLineRow + $0) }, uniquingKeysWith: { first, _ in first })
                hunkStarts = diff.hunks.compactMap { $0.lines.first.flatMap { rowOfNumbers[NumberPair($0)] } }
            }
        } else if let shown, empty == nil {
            for (hunkIndex, hunk) in shown.hunks.enumerated() {
                hunkStarts.append(rows.count)
                rows.append(.hunk(hunkIndex))
                rows += hunk.lines.indices.map { .line(hunk: hunkIndex, line: $0) }
            }
        }
        column.minWidth = contentWidth()
        table.reloadData()
        fitEmbeddedHeight()
        // The whole file opens where its first change is.
        if case .start(let sideways) = scrolling { scrollToTop(row: mode == .file ? hunkStarts.first ?? 0 : 0, resettingSideways: sideways) }
    }

    /// git's default context, so a jump in a word diff lands where the hunk would start.
    private static let contextAboveChange = 3

    /// The file changed only in whitespace or blank lines the options leave out.
    private static func leftOutContent(_ whitespace: DiffWhitespace) -> EmptyStateView.Content {
        let title = whitespace.ignoring == .nothing ? String(localized: "diff.empty.onlyBlankLines", defaultValue: "Only blank lines changed", bundle: .module) : String(localized: "diff.empty.onlyWhitespace", defaultValue: "Only whitespace changed", bundle: .module)
        return EmptyStateView.Content(title: title, detail: [String(localized: "diff.empty.leftOutHint", defaultValue: "The diff options hide these changes.", bundle: .module, comment: "Below 'Only whitespace changed' while Ignore Whitespace or Ignore blank Lines is on")])
    }

    /// What to say instead of lines, or nil when the diff has lines to show. A rename or mode change without content change says so rather than "no changes".
    private static func emptyContent(for diff: FileDiff?, encoding: WideTextEncoding?) -> EmptyStateView.Content? {
        guard let diff else { return EmptyStateView.Content(title: String(localized: "diff.empty.noChanges", defaultValue: "No changes", bundle: .module)) }
        if diff.isBinary, let encoding {
            let attribute = "\(diff.path) working-tree-encoding=\(encoding.workingTreeEncoding)"
            let detail = [
                String(localized: "diff.binary.info", defaultValue: "git treats this file as binary and shows no text comparison.", bundle: .module, comment: "Detail for a UTF-16 text file in the diff"),
                String(localized: "diff.binary.hint", defaultValue: "To compare it as text, add this line to .gitattributes:", bundle: .module, comment: "Followed by a .gitattributes line with working-tree-encoding"),
                attribute,
            ]
            return EmptyStateView.Content(title: String(localized: "diff.binary.textTitle", defaultValue: "\(encoding.name) Text", bundle: .module, comment: "Title for a text file in a wide encoding git treats as binary, e.g. UTF-16 LE Text"), detail: detail, toolTip: attribute)
        }
        if diff.isBinary { return EmptyStateView.Content(title: String(localized: "diff.binary.title", defaultValue: "Binary File", bundle: .module), detail: [String(localized: "diff.binary.detail", defaultValue: "No text comparison possible", bundle: .module)]) }
        guard diff.hunks.isEmpty else { return nil }
        let modes = diff.modeChanged ? diff.oldMode.flatMap { old in diff.newMode.map { "\(old) → \($0)" } } : nil
        if let oldPath = diff.oldPath {
            let title = diff.isCopy ? String(localized: "diff.empty.copied", defaultValue: "Copied, content unchanged", bundle: .module) : String(localized: "diff.empty.renamed", defaultValue: "Renamed, content unchanged", bundle: .module)
            let detail = [oldPath, "→ \(diff.path)"] + (modes.map { [String(localized: "diff.fileMode", defaultValue: "File mode \($0)", bundle: .module, comment: "e.g. File mode 100644 → 100755")] } ?? [])
            return EmptyStateView.Content(title: title, detail: detail, detailIsCode: true, toolTip: "\(oldPath) → \(diff.path)")
        }
        if let modes { return EmptyStateView.Content(title: String(localized: "diff.empty.modeOnly", defaultValue: "Only the file mode changed", bundle: .module), detail: [modes], detailIsCode: true) }
        if diff.isNew { return EmptyStateView.Content(title: String(localized: "diff.empty.added", defaultValue: "Empty file added", bundle: .module)) }
        if diff.isDeleted { return EmptyStateView.Content(title: String(localized: "diff.empty.deleted", defaultValue: "Empty file deleted", bundle: .module)) }
        return EmptyStateView.Content(title: String(localized: "diff.empty.noChanges", defaultValue: "No changes", bundle: .module))
    }

    /// Wide enough for the longest line, so long lines scroll sideways instead of being cut.
    private func contentWidth() -> CGFloat {
        let lines = mode == .file && !fileLines.isEmpty ? fileLines : shown?.hunks.flatMap(\.lines) ?? []
        return style.width(of: lines) + Theme.Space.xl
    }
}
