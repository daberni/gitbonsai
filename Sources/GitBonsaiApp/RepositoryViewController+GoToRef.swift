import AppKit
import GitEngine

/// "Go to Ref…" (⇧⌘O): every branch, remote branch, tag, worktree and stash in the command bar; ⏎ selects its commit and shows it in the sidebar, ⌥⏎ checks it out.
extension RepositoryViewController {
    func goToRefCommands(_ state: RepositoryCommandState) -> [Command] {
        [Command(.goToRef, blocker: CommandRules.goToRef(state), action: .choose(placeholder: LocalizedStringResource("command.goToRef.searchPlaceholder", defaultValue: "Search Branches, Tags, Worktrees and Stashes · ⌥⏎ checks out", bundle: .module)) { [weak self] in self?.refEntries(state) ?? [] })]
    }

    private func refEntries(_ state: RepositoryCommandState) -> [Command] {
        let worktrees = viewModel.worktrees.map { (worktree: $0.worktree, isCurrent: viewModel.isCurrent($0.worktree)) }
        return RefJump.targets(refs: viewModel.refs, worktrees: worktrees, stashes: viewModel.stashes).map { target in
            let entry = RefEntry(target: target, pill: Self.pill(for: target), strand: strand(of: target.commit), checkoutBlocked: CommandRules.checkout(target, state)?.reason.text) { [weak self] in self?.checkOut(target) }
            var command = Command(id: target.id, title: .verbatim(target.name), glyph: .glyph(glyph(for: target)), context: Self.context(of: target)) { [weak self] in self?.show(target) }
            command.ref = entry
            return command
        }
    }

    /// Selects the commit in the history and the branch or worktree in the sidebar.
    private func show(_ target: RefJump.Target) {
        if let commit = target.commit { history.navigate(to: commit) }
        sidebar.reveal(target)
    }

    private func checkOut(_ target: RefJump.Target) {
        switch target.kind {
        case .localBranch:
            checkoutController.perform(.localBranch(target.name), worktreePath: viewModel.branchesInOtherWorktrees["refs/heads/" + target.name]?.path)
        case .remoteBranch(let remote):
            checkoutController.perform(.remoteBranch(remote: remote, branch: String(target.name.dropFirst(remote.count + 1))), worktreePath: nil)
        case .tag:
            if let commit = target.commit { checkoutController.perform(.commit(commit), worktreePath: nil) }
        case .worktree(let path, _):
            onSwitchWorktree?(path)
        case .stash:
            break
        }
    }

    /// The colour of the commit's strand in the history, so the pill looks as it does there; muted for a commit not loaded yet.
    private func strand(of commit: String?) -> NSColor {
        guard let row = commit.flatMap(viewModel.rowIndex(of:)) else { return Theme.inkMuted }
        return Theme.strand(viewModel.rows[row].color)
    }

    private static func pill(for target: RefJump.Target) -> PillModel {
        let isHead = target.kind == .localBranch(isHead: true)
        let ref: PillRef = switch target.kind {
        case .localBranch: .branch(target.name)
        case .tag: .tag(target.name)
        default: .other(target.name)
        }
        return PillModel(name: target.name, glyphs: [], isHead: isHead, ref: ref)
    }

    /// The sidebar's glyphs: check where checked out, laptop, cloud, tag, bonsai, stash bowl.
    private func glyph(for target: RefJump.Target) -> Glyph {
        switch target.kind {
        case .localBranch(let isHead): isHead ? .check : .laptop
        case .remoteBranch: .cloud
        case .tag: .tag
        case .worktree(let path, _): viewModel.worktrees.first { $0.worktree.path == path }?.worktree.isMain == true ? .bonsaiMain : .bonsaiLinked
        case .stash: .stashBowl
        }
    }

    /// Short SHA, then what else names the ref: the worktree's branch, the stash's message.
    private static func context(of target: RefJump.Target) -> String? {
        let sha = target.commit.map { String($0.prefix(RefString.shortSHA)) }
        let parts = [sha, target.detail].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
