import AppKit
import GitEngine

extension FastForwardController: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        [Command(.fastForward, context: state.branch, blocker: CommandRules.fastForward(state), action: .choose(placeholder: LocalizedStringResource("checkout.command.searchPlaceholder", defaultValue: "Search Branches", bundle: .module)) { [weak self] in self?.targetChoices() ?? [] })]
    }

    /// Local and remote branches; those the current branch cannot fast-forward to stay listed, greyed out with the reason.
    private func targetChoices() -> [Command] {
        guard let current = viewModel.currentBranch, let head = viewModel.headSHA else { return [] }
        let descendants = descendants(of: head)
        return viewModel.refs.compactMap { ref -> Command? in
            let glyph: Glyph
            switch ref.kind {
            case .localBranch where ref.name != current: glyph = .laptop
            case .remoteBranch where !ref.name.hasSuffix("/HEAD"): glyph = .cloud
            default: return nil
            }
            // One walk for all targets: a target that descends from HEAD reaches it.
            let blocker = CommandRules.fastForward(branchHead: head, target: ref.target, reachableFromTarget: descendants.contains(ref.target) ? [head] : [])
            return Command(id: ref.fullName, title: .verbatim(ref.name), glyph: .glyph(glyph), blocker: blocker) { [weak self] in self?.fastForward(current, to: .ref(ref)) }
        }
    }

    /// The loaded commits whose history contains `head`. The history is in topological order, so walking it from the oldest commit sees every parent before its children.
    private func descendants(of head: String) -> Set<String> {
        var result: Set<String> = [head]
        for commit in viewModel.commits.reversed() where commit.parents.contains(where: result.contains) {
            result.insert(commit.id)
        }
        return result
    }
}
