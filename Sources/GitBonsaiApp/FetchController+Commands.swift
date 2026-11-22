import AppKit
import GitEngine

extension FetchController: CommandProvider {
    /// All remotes first, then each remote with and without prune, then the tags; the same variants as the Fetch button's menu.
    func commands(_ state: RepositoryCommandState) -> [Command] {
        let blocker = CommandRules.fetch(state)
        var commands = [Command(.fetchAll, blocker: blocker) { [weak self] in self?.fetch(.allRemotes) }]
        for remote in remotes {
            commands.append(Command(id: "fetch.remote.\(remote)", title: "Fetch \(remote)", keywords: ["fetch"], glyph: .glyph(.cloud), context: remote) { [weak self] in self?.fetch(.remote(remote, prune: false)) })
            commands.append(Command(id: "fetch.prune.\(remote)", title: "Fetch \(remote) and Prune Deleted Branches", keywords: ["fetch", "prune"], glyph: .glyph(.cloud), context: remote) { [weak self] in self?.fetch(.remote(remote, prune: true)) })
        }
        commands.append(Command(.fetchTags, blocker: blocker) { [weak self] in self?.fetch(.tags) })
        return commands
    }
}
