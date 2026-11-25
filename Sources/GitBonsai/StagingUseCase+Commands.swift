import AppKit
import GitEngine

extension StagingUseCase: CommandProvider {
    func commands(_ state: RepositoryCommandState) -> [Command] {
        [
            Command(.stageAll, blocker: CommandRules.stageAll(state)) { [weak self] in
                guard let self, let status = viewModel.status else { return }
                stage(status.unstaged.map(\.path))
            },
            Command(.unstageAll, blocker: CommandRules.unstageAll(state)) { [weak self] in
                guard let self, let status = viewModel.status else { return }
                unstage(status.staged.map(\.path))
            },
            Command(.discardAll, blocker: CommandRules.discardAll(state)) { [weak self] in self?.discardAll(.unstaged) },
        ]
    }
}
