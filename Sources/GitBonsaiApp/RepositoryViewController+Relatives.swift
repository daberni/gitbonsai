import AppKit
import GitEngine

/// "Go to Parent" and "Go to Child": one relative selects it in the history, several open the command bar with a row for each.
extension RepositoryViewController {
    enum Relation { case parent, child }

    func relativeCommands() -> [Command] {
        let commit = selectedHistoryCommit
        return [relativeCommand(.parent, of: commit), relativeCommand(.child, of: commit)]
    }

    /// The shortcut in the history (⌘↓ parent, ⌘↑ child).
    func goToRelative(_ relation: Relation) {
        guard let commit = selectedHistoryCommit else { return NSSound.beep() }
        let command = relativeCommand(relation, of: commit)
        guard command.isEnabled else { return NSSound.beep() }
        switch command.action {
        case .run(let perform): perform()
        case .choose: if let window = view.window { context.commandBar.open(in: window, commands: [command], step: command) }
        }
    }

    /// The commit of the single selected row; the working directory row is none.
    private var selectedHistoryCommit: Commit? {
        guard let row = singleSelectedRow, viewModel.kinds.indices.contains(row), viewModel.kinds[row] != .wip else { return nil }
        return viewModel.commits[row]
    }

    private static func spec(_ relation: Relation) -> CommandSpec {
        relation == .parent ? .goToParent : .goToChild
    }

    private func relativeCommand(_ relation: Relation, of commit: Commit?) -> Command {
        let found = commit.map { relatives(relation, of: $0) }
        let blocker = relation == .parent ? CommandRules.goToParent(parentCount: found?.count) : CommandRules.goToChild(childCount: found?.count)
        let spec = Self.spec(relation)
        guard let found, found.count > 1 else {
            let target = found?.first?.id
            return Command(spec, context: target.map { String($0.prefix(RefString.shortSHA)) }, blocker: blocker) { [weak self] in if let target { self?.show(target) } }
        }
        let placeholder: LocalizedStringResource
        if relation == .parent { placeholder = LocalizedStringResource("command.goToParent.placeholder", defaultValue: "Search Parents", bundle: .module) } else { placeholder = LocalizedStringResource("command.goToChild.placeholder", defaultValue: "Search Children", bundle: .module) }
        let context = String(localized: "common.commitCount", defaultValue: "\(found.count) commits", bundle: .module)
        return Command(spec, context: context, blocker: blocker, action: .choose(placeholder: placeholder) { [weak self] in self?.relativeEntries(found, relation: relation) ?? [] })
    }

    /// Stash rows stand for their base only, as in the graph; children are the loaded commits, stashes and working directory left out.
    private func relatives(_ relation: Relation, of commit: Commit) -> [CommitRelatives.Relative] {
        switch relation {
        case .parent:
            let parents = CommitRelatives.parents(of: commit)
            return viewModel.stashesByCommit[commit.id] == nil ? parents : Array(parents.prefix(1))
        case .child:
            let commits = zip(viewModel.commits, viewModel.kinds).filter { $0.1 == .commit || $0.1 == .merge }.map(\.0)
            return CommitRelatives.children(of: commit.id, in: commits)
        }
    }

    /// One row per relative: its subject, then short SHA, "first parent" and the branches pointing at it.
    private func relativeEntries(_ relatives: [CommitRelatives.Relative], relation: Relation) -> [Command] {
        relatives.map { relative in
            let commit = viewModel.rowIndex(of: relative.id).map { viewModel.commits[$0] }
            var parts = [String(relative.id.prefix(RefString.shortSHA))]
            if relation == .parent, relative.isFirstParent { parts.append(String(localized: "command.goToParent.firstParent", defaultValue: "first parent", bundle: .module, comment: "Marks the parent a merge was made on in the Go to Parent list.")) }
            parts += (viewModel.refsByCommit[relative.id] ?? []).filter { switch $0.kind { case .localBranch, .remoteBranch: true; default: false } }.map(\.name)
            let title = commit?.subject ?? String(relative.id.prefix(RefString.shortSHA))
            return Command(id: "relative.\(relative.id)", title: .verbatim(title), glyph: .symbol(relation == .parent ? "arrow.down.circle" : "arrow.up.circle"), context: parts.joined(separator: " · ")) { [weak self] in self?.show(relative.id) }
        }
    }

    /// The whole history streams in; a commit not loaded yet is selected once the load finished.
    private func show(_ id: String) {
        if viewModel.rowIndex(of: id) != nil || !viewModel.isLoading { return history.navigate(to: id) }
        let load = viewModel.loadTask
        Task { [weak self] in
            await load?.value
            self?.history.navigate(to: id)
        }
    }
}
