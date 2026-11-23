import AppKit
import GitEngine

extension StagingController: CommandProvider {
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
            Command(.discardAll, blocker: CommandRules.discardAll(state)) { [weak self] in self?.discardAllTrackedChanges() },
        ]
    }

    /// Takes back every unstaged change of a tracked file after asking. Staged changes and untracked files stay, as `git restore --worktree` leaves them.
    private func discardAllTrackedChanges() {
        guard let status = viewModel.status else { return }
        let paths = status.entries.filter { !$0.isUntracked && !$0.isIgnored && $0.conflict == nil && $0.worktreeState != .unmodified }.map(\.path)
        guard !paths.isEmpty else { return }
        let prompter = ActionPrompter()
        prompter.window = window
        let runner = ActionRunner(viewModel: viewModel, prompter: prompter)
        Task { [weak self] in
            guard await runner.confirm(LocalizedStringResource("files.discardAll.title", defaultValue: "Discard all Changes?", bundle: .module), info: LocalizedStringResource("files.discardAll.info", defaultValue: "Unstaged changes to \(paths.count) files are lost.", bundle: .module), button: LocalizedStringResource("common.discard", defaultValue: "Discard", bundle: .module)) else { return }
            runner.run(failure: LocalizedStringResource("failure.files.notDiscarded", defaultValue: "Changes not discarded", bundle: .module), note: "git restore --worktree -- …", then: { self?.onChange?() }) { repository in
                try await repository.discardUnstagedChanges(paths)
            }
        }
    }
}
