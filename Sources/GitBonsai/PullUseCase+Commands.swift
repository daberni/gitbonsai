import AppKit
import GitEngine

extension PullUseCase: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        pullCommands(state)
    }

    /// Pull with the configured mode first, then the other modes, as in the Pull button's menu; every one carries local changes. Without upstream the bar offers to set one.
    private func pullCommands(_ state: RepositoryCommandState) -> [Command] {
        let blocker = CommandRules.pull(state)
        let context = status.upstream?.name ?? state.upstream
        // The mode is taken now, so the title and what runs always agree.
        let standard = defaultMode
        let standardContext = context.map { "\($0) · \(Self.label(of: standard))" }
        var commands = [Command(.pull, context: standardContext, blocker: blocker) { [weak self] in self?.pull(PullVariant(mode: standard)) }]
        for mode in PullMode.allCases where mode != standard {
            commands.append(Command(id: "pull.\(mode)", title: Self.commandTitle(of: mode), glyph: .symbol("arrow.down"), context: context, blocker: blocker) { [weak self] in self?.pull(PullVariant(mode: mode)) })
        }
        if blocker == .noUpstream {
            let noCandidates: LocalizedStringResource? = remoteBranches().isEmpty ? LocalizedStringResource("pull.command.noRemoteBranches", defaultValue: "No remote branches", bundle: .module) : nil
            commands.append(Command(.setUpstreamAndPull, context: state.branch, disabledReason: noCandidates) { [weak self] in self?.setUpstreamAndPull() })
        }
        return commands
    }

    private static func label(of mode: PullMode) -> String {
        switch mode {
        case .fastForwardOnly: String(localized: "pull.mode.fastForward", defaultValue: "Fast-Forward", bundle: .module, comment: "Pull mode.")
        case .merge: String(localized: "pull.mode.merge", defaultValue: "Merge", bundle: .module, comment: "Pull mode.")
        case .rebase: String(localized: "pull.mode.rebase", defaultValue: "Rebase", bundle: .module, comment: "Pull mode.")
        }
    }

    private static func commandTitle(of mode: PullMode) -> LocalizedStringResource {
        switch mode {
        case .fastForwardOnly: LocalizedStringResource("pull.command.fastForward", defaultValue: "Pull with fast-forward", bundle: .module)
        case .merge: LocalizedStringResource("pull.command.merge", defaultValue: "Pull with merge", bundle: .module)
        case .rebase: LocalizedStringResource("pull.command.rebase", defaultValue: "Pull with rebase", bundle: .module)
        }
    }
}
