import AppKit
import GitEngine

extension CheckoutUseCase: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        [Command(.checkout, context: state.branch, blocker: CommandRules.checkout(state), action: .choose(placeholder: LocalizedStringResource("checkout.command.searchPlaceholder", defaultValue: "Search Branches", bundle: .module)) { [weak self] in self?.branchChoices() ?? [] })]
    }

    /// Local branches with the sidebar's glyphs, then remote branches; the checked-out branch stays listed, greyed out.
    /// A branch checked out in another worktree switches there, as a double-click in the sidebar does.
    private func branchChoices() -> [Command] {
        let elsewhere = viewModel.branchesInOtherWorktrees
        var commands: [Command] = []
        for ref in viewModel.refs {
            switch ref.kind {
            case .localBranch:
                let worktree = elsewhere[ref.fullName]
                let context = worktree.map { String(localized: "checkout.command.inWorktree", defaultValue: "in worktree \(($0.path as NSString).lastPathComponent)", bundle: .module, comment: "Where a branch in the checkout list is checked out.") }
                commands.append(Command(id: ref.fullName, title: .verbatim(ref.name), glyph: .glyph(ref.isHead ? .check : .laptop), context: context, disabledReason: ref.isHead ? LocalizedStringResource("checkout.command.checkedOut", defaultValue: "Checked out", bundle: .module) : nil) { [weak self] in
                    self?.perform(.localBranch(ref.name), worktreePath: worktree?.path)
                })
            case .remoteBranch(let remote) where !ref.name.hasSuffix("/HEAD"):
                let branch = String(ref.name.dropFirst(remote.count + 1))
                commands.append(Command(id: ref.fullName, title: .verbatim(ref.name), glyph: .glyph(.cloud), context: remote) { [weak self] in
                    self?.perform(.remoteBranch(remote: remote, branch: branch), worktreePath: nil)
                })
            default:
                break
            }
        }
        return commands
    }
}
