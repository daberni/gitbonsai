import AppKit
import GitEngine

extension PushUseCase: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        pushCommands(state)
    }

    /// Push to the upstream, or the first push that sets one; then the tags for each remote.
    private func pushCommands(_ state: RepositoryCommandState) -> [Command] {
        let pushContext = status.upstream?.name ?? state.upstream ?? (state.branch == nil ? nil : String(localized: "pull.command.setUpstream", defaultValue: "Set upstream", bundle: .module, comment: "Command bar context of Push for a branch without upstream."))
        var commands = [Command(.push, context: pushContext, blocker: CommandRules.push(state)) { [weak self] in self?.pushCurrentBranch() }]
        let tagRemotes = state.remotes.isEmpty ? [nil] : state.remotes.map(Optional.some)
        for remote in tagRemotes {
            commands.append(Command(id: "push.tags.\(remote ?? "")", title: LocalizedStringResource("push.command.tags", defaultValue: "Push Tags", bundle: .module), keywords: Command.searchWords(LocalizedStringResource("command.push.keywords", defaultValue: "push, upload, publish", bundle: .module)), glyph: .glyph(.tag), context: remote, blocker: CommandRules.pushTags(state)) { [weak self] in
                guard let remote else { return }
                self?.pushTags(.tags(remote: remote))
            })
        }
        return commands
    }

    private func pushCurrentBranch() {
        guard let branch = status.branch, let upstream = status.upstream else { return firstPush() }
        push(.branch(branch, remote: upstream.remote, remoteBranch: upstream.branch, setUpstream: false, forceWithLease: false), upstream: upstream.name)
    }

}
