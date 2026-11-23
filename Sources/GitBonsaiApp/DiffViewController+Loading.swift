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
        let loadsLargeImages = loadsLargeImages
        loadTask = Task { [weak self] in
            let read = try? await Self.read(selection, mode: mode, loadingLargeImages: loadsLargeImages, from: repository)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            if load.closesWhenGone {
                // A failed read, such as a lock held for a moment, says nothing about the file; only a diff that is gone closes the view.
                guard let read else { return }
                guard read.diff != nil else { onClose?(); return }
            }
            self.selection = selection
            images = read?.images
            apply(read?.diff, full: read?.full, encoding: read?.encoding, scrolling: load.scroll)
            load.ready.forEach { $0() }
        }
    }

    private struct Read {
        let diff: FileDiff?
        let full: FileDiff?
        let encoding: WideTextEncoding?
        let images: ImageDiffContent?
    }

    /// The diff, and in the "Whole file" mode also the whole file; both are read before either is shown. A binary file is checked for UTF-16 text.
    /// A changed image also reads both of its sides.
    private static func read(_ selection: FileSelection, mode: DiffMode, loadingLargeImages: Bool, from repository: Repository) async throws -> Read {
        async let diff = repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source)
        async let full = mode == .file ? repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source, fullFile: true) : nil
        let (readDiff, readFull) = try await (diff, full)
        guard let readDiff else { return Read(diff: nil, full: readFull, encoding: nil, images: nil) }
        let images = await ImageDiffLoader.load(readDiff, path: selection.path, source: selection.source, from: repository, loadingLarge: loadingLargeImages)
        if case .images = images { return Read(diff: readDiff, full: readFull, encoding: nil, images: images) }
        guard readDiff.isBinary else { return Read(diff: readDiff, full: readFull, encoding: nil, images: images) }
        return Read(diff: readDiff, full: readFull, encoding: await repository.wideTextEncoding(of: readDiff, in: selection.source), images: images)
    }

    /// Options change how the lines are drawn, not what was read.
    func changeOptions(to newOptions: DiffOptions) {
        guard newOptions != style.options else { return }
        style.options = newOptions
        DiffOptions.remembered = newOptions
        column.minWidth = contentWidth()
        table.reloadData()
    }

    private func apply(_ diff: FileDiff?, full: FileDiff?, encoding: WideTextEncoding?, scrolling: PendingLoad.Scroll) {
        guard let selection else { return }
        self.diff = diff
        fileLines = full?.hunks.flatMap(\.lines) ?? []
        header.show(selection, diff: diff, mode: mode, options: style.options)
        style.prepare(diff: diff, fileLines: fileLines)
        rows = imageNotice.map { [.notice($0)] } ?? []
        rows += style.notice.map { [.notice($0)] } ?? []
        hunkStarts = []
        let showsImages = applyImages()
        let empty = showsImages ? nil : Self.emptyContent(for: diff, encoding: encoding)
        if let empty { emptyState.show(empty) }
        emptyState.isHidden = empty == nil
        scroll.isHidden = empty != nil || showsImages
        if let diff, empty == nil, mode == .file, !fileLines.isEmpty {
            let firstLineRow = rows.count
            rows += fileLines.indices.map { .fileLine($0) }
            // A hunk starts with the same line in both views, and a line's pair of old and new number occurs once in the file.
            let rowOfNumbers = Dictionary(fileLines.enumerated().map { (NumberPair($1), firstLineRow + $0) }, uniquingKeysWith: { first, _ in first })
            hunkStarts = diff.hunks.compactMap { $0.lines.first.flatMap { rowOfNumbers[NumberPair($0)] } }
        } else if let diff, empty == nil {
            for (hunkIndex, hunk) in diff.hunks.enumerated() {
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
        let lines = mode == .file && !fileLines.isEmpty ? fileLines : diff?.hunks.flatMap(\.lines) ?? []
        return style.width(of: lines) + Theme.Space.xl
    }
}
