import AppKit
import GitEngine

extension StashesController: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        [
            Command(.stash, blocker: CommandRules.stash(state)) { [weak self] in self?.stashChanges() },
            Command(.pop, context: state.stashCount > 0 ? "stash@{0}" : nil, blocker: CommandRules.pop(state)) { [weak self] in self?.popNewest() },
        ]
    }
}
