import AppKit
import GitEngine

/// The detail panel while several commits are selected: what is compared, the git command behind it and the files that differ.
/// Two commits compare directly, or from their merge base when they sit on different branches; a run on one line is combined like a squash; anything else lists each commit on its own.
@MainActor
final class ComparisonDetail: NSObject {
    let commits: [Commit]
    let headline: NSTextField
    let command: NSTextField
    let note: NSTextField
    let baseSwitch = LabeledCheckbox(title: "seit gemeinsamer Basis")
    let filesHeader: NSTextField
    var list: FileListView?
    /// The file list was replaced after the base switch changed; an open diff follows its file.
    var onFilesReplaced: (([FileRowView.Model]) -> Void)?
    private(set) var comparison: CommitComparison?
    private(set) var sinceMergeBase = false
    private let repository: Repository
    private var loadTask: Task<Void, Never>?

    init(commits: [Commit], repository: Repository, label: (_ font: NSFont, _ color: NSColor) -> NSTextField) {
        self.commits = commits
        self.repository = repository
        headline = label(Theme.title, Theme.ink)
        command = label(Theme.monoSmall, Theme.inkMuted)
        note = label(Theme.caption, Theme.inkMuted)
        filesHeader = label(Theme.caption, Theme.inkMuted)
        super.init()
        headline.stringValue = "\(commits.count) Commits"
        note.isHidden = true
        baseSwitch.isHidden = true
        baseSwitch.target = self
        baseSwitch.action = #selector(toggleBase(_:))
        baseSwitch.toolTip = "Nur die Änderungen des neueren Commits seit dem gemeinsamen Vorfahren (git diff <a>...<b>)"
    }

    func load() {
        loadTask?.cancel()
        let repository = repository
        let commits = commits
        loadTask = Task { [weak self] in
            let comparison = await repository.comparison(of: commits)
            guard let self, !Task.isCancelled else { return }
            self.comparison = comparison
            describe()
            await loadFiles(replacing: false)
        }
    }

    func cancel() {
        loadTask?.cancel()
    }

    @objc private func toggleBase(_ sender: LabeledCheckbox) {
        sinceMergeBase = sender.isOn
        describe()
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.loadFiles(replacing: true) }
    }

    // MARK: Text

    private func describe() {
        guard let comparison else { return }
        switch comparison {
        case .pair(let older, let newer, let base):
            headline.stringValue = "\(older.shortID) → \(newer.shortID) · 2 Commits"
            command.stringValue = sinceMergeBase ? "git diff \(older.shortID)...\(newer.shortID)" : "git diff \(older.shortID) \(newer.shortID)"
            baseSwitch.isHidden = base == nil
            note.isHidden = base == nil
            if let base {
                note.setText(sinceMergeBase ? "Nur was \(commit: newer.id) seit der gemeinsamen Basis \(commit: base) geändert hat." : "Die Commits liegen auf verschiedenen Branches; der Diff enthält auch, was nur \(commit: older.id) hat.")
            }
        case .run(let run):
            let oldest = run[run.count - 1]
            headline.stringValue = "\(oldest.shortID) → \(run[0].shortID) · \(run.count) Commits"
            command.stringValue = oldest.parents.isEmpty ? "git diff <leerer Baum> \(run[0].shortID)" : "git diff \(oldest.shortID)^ \(run[0].shortID)"
            note.stringValue = "Zusammengefasst wie ein Squash."
            note.isHidden = false
        case .separate(let commits):
            headline.stringValue = commits.reversed().map(\.shortID).joined(separator: ", ") + " · \(commits.count) Commits"
            command.stringValue = "git show " + commits.map(\.shortID).joined(separator: " ")
            note.stringValue = "Kein kombinierter Diff: Die Commits folgen nicht direkt aufeinander auf einer Linie, ein gemeinsamer Diff zeigte auch die Änderungen dazwischen. Jeder Commit steht für sich."
            note.isHidden = false
        }
    }

    // MARK: Files

    private func loadFiles(replacing: Bool) async {
        guard let comparison else { return }
        var sections: [FileListView.Section] = []
        var all: [ChangedFile] = []
        switch comparison {
        case .pair(let older, let newer, let base):
            let from = sinceMergeBase ? base ?? older.id : older.id
            let files = (try? await repository.changedFiles(from: from, to: newer.id)) ?? []
            all = files
            sections = [FileListView.Section(title: "Dateien", rows: files.map { Self.row($0, source: .revisions(base: from, target: newer.id)) }, action: nil)]
        case .run(let run):
            guard let oldest = run.last, let from = try? await repository.base(before: oldest) else { return }
            let files = (try? await repository.changedFiles(from: from, to: run[0].id)) ?? []
            all = files
            sections = [FileListView.Section(title: "Dateien", rows: files.map { Self.row($0, source: .revisions(base: from, target: run[0].id)) }, action: nil)]
        case .separate(let commits):
            let repository = repository
            let perCommit = await withTaskGroup(of: (Int, [ChangedFile]).self) { group in
                for (index, commit) in commits.enumerated() {
                    group.addTask { (index, (try? await repository.changedFiles(of: commit)) ?? []) }
                }
                var result = [[ChangedFile]](repeating: [], count: commits.count)
                for await (index, files) in group { result[index] = files }
                return result
            }
            all = perCommit.flatMap { $0 }
            sections = zip(commits, perCommit).map { commit, files in
                FileListView.Section(title: "\(commit.shortID)  \(commit.subject)", rows: files.map { Self.row($0, source: .commit(commit)) }, action: nil)
            }
        }
        guard !Task.isCancelled, let list else { return }
        let total = all.compactMap(\.stat).reduce(DiffStat(added: 0, removed: 0)) { DiffStat(added: $0.added + $1.added, removed: $0.removed + $1.removed) }
        let summary = NSMutableAttributedString(string: (all.count == 1 ? "1 Datei" : "\(all.count) Dateien") + " · ", attributes: [.font: Theme.caption, .foregroundColor: Theme.inkMuted])
        summary.append(FileRowView.statText(total))
        filesHeader.attributedStringValue = summary
        list.show(sections)
        if replacing { onFilesReplaced?(list.models) }
    }

    private static func row(_ file: ChangedFile, source: DiffSource) -> FileRowView.Model {
        FileRowView.Model(selection: FileSelection(path: file.path, originalPath: file.originalPath, source: source), letter: String(file.state.rawValue), color: file.state.tint, stat: file.stat, note: file.stat == nil && file.state != .deleted ? "binär" : nil, state: file.state)
    }

    /// Everything the panel says, for harness checks.
    var summary: String {
        let switchState = baseSwitch.isHidden ? "no base switch" : "base switch \(baseSwitch.isOn ? "on" : "off")"
        let files = list?.models.map { "\($0.letter) \($0.selection.path)" }.joined(separator: ", ") ?? ""
        return "\"\(headline.stringValue)\" | \(command.stringValue) | \(note.isHidden ? "no note" : "note \"\(note.stringValue)\"") | \(switchState) | \(filesHeader.stringValue) | files: \(files)"
    }
}

extension DetailView {
    /// Several selected commits: what they compare and the files that differ.
    func showComparison(of commits: [Commit], repository: Repository) -> ComparisonDetail {
        reset(title: "Vergleich")
        let panel = ComparisonDetail(commits: commits, repository: repository) { [unowned self] font, color in label("", font: font, color: color, wraps: true) }
        add(panel.headline)
        add(panel.command)
        add(panel.note)
        add(panel.baseSwitch, fill: false)
        add(divider())
        add(panel.filesHeader)
        panel.list = makeFileList()
        panel.load()
        return panel
    }
}
