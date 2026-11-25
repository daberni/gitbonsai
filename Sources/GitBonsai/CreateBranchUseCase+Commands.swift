import AppKit
import GitEngine

extension CreateBranchUseCase: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        [Command(.newBranch, blocker: CommandRules.newBranch(state)) { [weak self] in self?.show() }]
    }
}
