import AppKit
import GitEngine

/// How the lines of one diff are drawn: the changed part of each paired line, a notice for a line ending conversion, and the invisible characters the options ask for.
@MainActor
struct DiffLineStyle {
    var options: DiffOptions
    /// The changed part of each paired line, by hunk and line index, or by line index of the whole file.
    private var hunkChanges: [[Int: IntralineChange]] = []
    private var fileChanges: [Int: IntralineChange] = [:]
    /// Set when every line only changed its ending; one notice replaces the markers on each line.
    private var lineEndingConversion: (from: LineEnding, to: LineEnding)?

    init(options: DiffOptions) {
        self.options = options
    }

    /// Pairs the lines of a newly read diff; linear in the length of the paired lines.
    mutating func prepare(diff: FileDiff?, fileLines: [DiffLine]) {
        hunkChanges = diff?.hunks.map { IntralineDiff.changes(in: $0.lines) } ?? []
        fileChanges = IntralineDiff.changes(in: fileLines)
        lineEndingConversion = diff?.lineEndingConversion
    }

    var notice: String? {
        lineEndingConversion.map { String(localized: "diff.lineEndings", defaultValue: "Line endings: \($0.from.rawValue) → \($0.to.rawValue)", bundle: .module, comment: "Notice above a diff in which every line only changed its line ending, e.g. Line endings: LF → CRLF") }
    }

    func content(ofHunk hunk: Int, line: Int, in diff: FileDiff) -> DiffLineView.Content {
        content(diff.hunks[hunk].lines[line], change: hunkChanges.indices.contains(hunk) ? hunkChanges[hunk][line] : nil)
    }

    func content(ofFileLine index: Int, in fileLines: [DiffLine]) -> DiffLineView.Content {
        content(fileLines[index], change: fileChanges[index])
    }

    /// Wide enough for the longest line, so long lines scroll sideways instead of being cut.
    func width(of lines: [DiffLine]) -> CGFloat {
        let longest = lines.map { DiffLineText.columns(of: DiffLineText.runs($0.text, options: textOptions(for: $0, change: nil))) }.max() ?? 0
        return DiffLineView.width(ofColumns: longest)
    }

    private func content(_ line: DiffLine, change: IntralineChange?) -> DiffLineView.Content {
        guard !line.segments.isEmpty else { return DiffLineView.Content(line: line, runs: DiffLineText.runs(line.text, options: textOptions(for: line, change: change))) }
        // A word diff line that kept some words: each changed word is emphasized on its own, in the colour of its side.
        let words = line.segments.map { segment in
            var options = textOptions(for: line, change: nil)
            options.isChanged = segment.kind != .context
            options.emphasis = segment.kind == .context ? nil : 0..<segment.text.unicodeScalars.count
            options.isFileStart = options.isFileStart && segment == line.segments.first
            return DiffLineView.Word(kind: segment.kind, runs: DiffLineText.runs(segment.text, options: options))
        }
        return DiffLineView.Content(line: line, runs: [], words: words)
    }

    private func textOptions(for line: DiffLine, change: IntralineChange?) -> DiffLineText.Options {
        let showsInvisibles = options.showsInvisibles
        return DiffLineText.Options(
            showsInvisibles: showsInvisibles,
            isChanged: line.kind != .context,
            isFileStart: line.oldNumber == 1 || line.newNumber == 1,
            marksCarriageReturn: showsInvisibles && line.carriageReturn && lineEndingConversion == nil,
            carriageReturnEmphasized: change?.lineEndingChanged ?? false,
            emphasis: change?.range,
            tabWidth: Theme.Diff.tabWidth
        )
    }
}
