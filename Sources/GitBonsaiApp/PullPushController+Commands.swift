import AppKit
import GitEngine

extension PullPushController: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        pullCommands(state) + pushCommands(state)
    }

    /// Pull with the configured mode first, then the other modes, as in the Pull button's menu; every one carries local changes. Without upstream the bar offers to set one.
    private func pullCommands(_ state: RepositoryCommandState) -> [Command] {
        let blocker = CommandRules.pull(state)
        let context = upstream?.name ?? state.upstream
        // The mode is taken now, so the title and what runs always agree.
        let standard = defaultMode
        let standardContext = context.map { "\($0) · \(Self.label(of: standard))" }
        var commands = [Command(.pull, context: standardContext, blocker: blocker) { [weak self] in self?.pull(PullVariant(mode: standard)) }]
        for mode in PullMode.allCases where mode != standard {
            commands.append(Command(id: "pull.\(mode)", title: Self.commandTitle(of: mode), glyph: .symbol("arrow.down"), context: context, blocker: blocker) { [weak self] in self?.pull(PullVariant(mode: mode)) })
        }
        if blocker == .noUpstream {
            let noCandidates: LocalizedStringResource? = remoteBranches().isEmpty ? "No remote branches" : nil
            commands.append(Command(.setUpstreamAndPull, context: state.branch, disabledReason: noCandidates) { [weak self] in self?.setUpstreamAndPull() })
        }
        return commands
    }

    /// Push to the upstream, or the first push that sets one; then the tags for each remote.
    private func pushCommands(_ state: RepositoryCommandState) -> [Command] {
        let pushContext = upstream?.name ?? state.upstream ?? (state.branch == nil ? nil : String(localized: "Set upstream", bundle: .module, comment: "Command bar context of Push for a branch without upstream."))
        var commands = [Command(.push, context: pushContext, blocker: CommandRules.push(state)) { [weak self] in self?.pushCurrentBranch() }]
        let tagRemotes = state.remotes.isEmpty ? [nil] : state.remotes.map(Optional.some)
        for remote in tagRemotes {
            commands.append(Command(id: "push.tags.\(remote ?? "")", title: "Push Tags", keywords: ["push"], glyph: .glyph(.tag), context: remote, blocker: CommandRules.pushTags(state)) { [weak self] in
                guard let remote else { return }
                self?.pushTags(.tags(remote: remote))
            })
        }
        return commands
    }

    private func pushCurrentBranch() {
        guard let branch, let upstream else { return firstPush() }
        push(.branch(branch, remote: upstream.remote, remoteBranch: upstream.branch, setUpstream: false, forceWithLease: false), upstream: upstream.name)
    }

    private static func label(of mode: PullMode) -> String {
        switch mode {
        case .fastForwardOnly: String(localized: "Fast-Forward", bundle: .module, comment: "Pull mode.")
        case .merge: String(localized: "Merge", bundle: .module, comment: "Pull mode.")
        case .rebase: String(localized: "Rebase", bundle: .module, comment: "Pull mode.")
        }
    }

    private static func commandTitle(of mode: PullMode) -> LocalizedStringResource {
        switch mode {
        case .fastForwardOnly: "Pull with Fast-Forward"
        case .merge: "Pull with Merge"
        case .rebase: "Pull with Rebase"
        }
    }
}
