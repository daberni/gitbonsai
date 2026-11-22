import AppKit
import GitEngine

/// Reads the diff or the whole file of the shown selection and lays out its lines.
extension DiffViewController {
    // MARK: Loading

    /// Reads the file's diff and only then replaces what is shown, so the previous diff never flashes up. `ready` runs once the new one is in place.
    func show(_ selection: FileSelection, ready: (() -> Void)? = nil) {
        let isNewFile = selection != self.selection
        loadTask?.cancel()
        let repository = self.repository()
        let mode = mode
        loadTask = Task { [weak self] in
            let (diff, full, encoding) = await Self.read(selection, mode: mode, from: repository)
            guard let self, !Task.isCancelled else { return }
            self.selection = selection
            apply(diff, full: full, encoding: encoding, scrollToTop: isNewFile)
            ready?()
        }
    }

    /// The history moved on: a diff still loading must not appear, and a later reload has nothing to read again.
    func close() {
        loadTask?.cancel()
        selection = nil
    }

    /// After the index changed: the same file, read again. Once it has no changes left on the side shown, the diff closes.
    func reload() {
        guard let selection else { return }
        let repository = self.repository()
        loadTask?.cancel()
        let mode = mode
        loadTask = Task { [weak self] in
            let (diff, full, encoding) = await Self.read(selection, mode: mode, from: repository)
            guard let self, !Task.isCancelled else { return }
            guard diff != nil else {
                onClose?()
                return
            }
            apply(diff, full: full, encoding: encoding, scrollToTop: false)
        }
    }

    /// The diff, and in the "Whole file" mode also the whole file; both are read before either is shown. A binary file is checked for UTF-16 text.
    private static func read(_ selection: FileSelection, mode: DiffMode, from repository: Repository) async -> (FileDiff?, FileDiff?, WideTextEncoding?) {
        async let diff = try? repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source)
        async let full = mode == .file ? try? repository.diff(of: selection.path, originalPath: selection.originalPath, in: selection.source, fullFile: true) : nil
        let (readDiff, readFull) = await (diff, full)
        guard let readDiff, readDiff.isBinary else { return (readDiff, readFull, nil) }
        return (readDiff, readFull, await repository.wideTextEncoding(of: readDiff, in: selection.source))
    }

    /// The new mode holds for this file right away and for every file after it.
    func switchMode(to newMode: DiffMode) {
        guard newMode != mode, let selection else { return }
        mode = newMode
        DiffMode.remembered = newMode
        loadTask?.cancel()
        let repository = self.repository()
        loadTask = Task { [weak self] in
            let (diff, full, encoding) = await Self.read(selection, mode: newMode, from: repository)
            guard let self, !Task.isCancelled else { return }
            apply(diff, full: full, encoding: encoding, scrollToTop: true)
        }
    }

    /// Options change how the lines are drawn, not what was read.
    func changeOptions(to newOptions: DiffOptions) {
        guard newOptions != style.options else { return }
        style.options = newOptions
        DiffOptions.remembered = newOptions
        column.minWidth = contentWidth()
        table.reloadData()
    }

    private func apply(_ diff: FileDiff?, full: FileDiff?, encoding: WideTextEncoding?, scrollToTop: Bool) {
        guard let selection else { return }
        self.diff = diff
        fileLines = full?.hunks.flatMap(\.lines) ?? []
        header.show(selection, diff: diff, mode: mode, options: style.options)
        style.prepare(diff: diff, fileLines: fileLines)
        rows = style.notice.map { [.notice($0)] } ?? []
        hunkStarts = []
        let empty = Self.emptyContent(for: diff, encoding: encoding)
        if let empty { emptyState.show(empty) }
        emptyState.isHidden = empty == nil
        scroll.isHidden = empty != nil
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
        // The whole file opens where its first change is.
        if scrollToTop { self.scrollToTop(row: mode == .file ? hunkStarts.first ?? 0 : 0) }
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
