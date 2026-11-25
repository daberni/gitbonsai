import AppKit
import GitEngine

extension StashActions: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        [
            Command(.stash, blocker: CommandRules.stash(state)) { [weak self] in self?.stashNow(.includingUntracked) },
            Command(.stashWithMessage, blocker: CommandRules.stash(state)) { [weak self] in self?.stashWithMessage() },
            Command(.stashStaged, blocker: CommandRules.stash(state), disabledReason: hasStagedChanges ? nil : LocalizedStringResource("stash.command.noStagedChanges", defaultValue: "No staged changes", bundle: .module)) { [weak self] in self?.stashNow(.staged) },
            Command(.pop, context: state.stashCount > 0 ? "stash@{0}" : nil, blocker: CommandRules.pop(state)) { [weak self] in self?.popNewest() },
        ]
    }
}
