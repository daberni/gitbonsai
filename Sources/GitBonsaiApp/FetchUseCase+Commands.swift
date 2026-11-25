import AppKit
import GitEngine

extension FetchUseCase: CommandProvider {
    /// All remotes first, then each remote with and without prune, then the tags; the same variants as the Fetch button's menu.
    func commands(_ state: RepositoryCommandState) -> [Command] {
        let blocker = CommandRules.fetch(state)
        var commands = [Command(.fetchAll, blocker: blocker) { [weak self] in self?.fetch(.allRemotes) }]
        for remote in remotes {
            commands.append(Command(id: "fetch.remote.\(remote)", title: LocalizedStringResource("fetch.action.remote", defaultValue: "Fetch \(remote)", bundle: .module), keywords: Command.searchWords(LocalizedStringResource("command.fetch.keywords", defaultValue: "fetch, download, update", bundle: .module)), glyph: .glyph(.cloud), context: remote) { [weak self] in self?.fetch(.remote(remote, prune: false)) })
            commands.append(Command(id: "fetch.prune.\(remote)", title: LocalizedStringResource("fetch.action.remotePrune", defaultValue: "Fetch \(remote) and Prune deleted Branches", bundle: .module), keywords: Command.searchWords(LocalizedStringResource("command.fetchPrune.keywords", defaultValue: "fetch, prune, clean up", bundle: .module)), glyph: .glyph(.cloud), context: remote) { [weak self] in self?.fetch(.remote(remote, prune: true)) })
        }
        commands.append(Command(.fetchTags, blocker: blocker) { [weak self] in self?.fetch(.tags) })
        return commands
    }
}
