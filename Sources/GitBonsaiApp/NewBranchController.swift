import AppKit
import GitEngine

/// The "Neuer Branch" sheet of the Local header's plus and the toolbar's Branch button: loads what the start point picker offers, shows the sheet and runs git with the answer.
@MainActor
final class NewBranchController {
    private let runner: SidebarActionRunner
    private var viewModel: GraphViewModel { runner.viewModel }
    /// The sheet while it is open, for the harness.
    private(set) var sheet: NewBranchSheet?

    init(runner: SidebarActionRunner) {
        self.runner = runner
    }

    /// `commit` is offered under "Aktuell" next to HEAD and preselected, such as a commit selected in the history; HEAD when nil.
    func show(commit: Commit? = nil) {
        guard sheet == nil, let parent = runner.prompter.window?() else { return }
        let repository = viewModel.repository
        Task {
            let tips = (try? await repository.refTips()) ?? []
            let headBranch = viewModel.refs.first { $0.kind == .localBranch && $0.isHead }?.name
            let headCommit = await repository.commitSummary("HEAD")
            var current: [RefCatalog.Item] = headCommit.map { [.head(branch: headBranch, commit: $0)] } ?? []
            let picked = commit.map { RefCatalog.Item.commit(CommitSummary(sha: $0.id, date: $0.committerDate, subject: $0.subject)) }
            if let picked { current.append(picked) }
            let picker = RefPicker(repository: repository)
            picker.setCatalog(RefCatalog(tips: tips, current: current), selection: picked ?? current.first)
            let existing = Set(tips.filter { $0.kind == .localBranch }.map(\.name))
            let form = NewBranchViewController(repository: repository, existingBranches: existing, picker: picker) { [runner] name in runner.defaultWorktreePath(suffix: name) }
            let sheet = NewBranchSheet(form: form)
            self.sheet = sheet
            ScreenshotHarness.driveNewBranchSheet(sheet)
            let request = await sheet.run(on: parent)
            self.sheet = nil
            if let request { await create(request) }
        }
    }

    private func create(_ request: NewBranchRequest) async {
        let name = request.name
        let start = request.start
        switch request.follow {
        case .stay:
            await runner.run(failure: "Branch nicht angelegt", note: "git branch") { try await $0.createBranch(name, at: start, checkout: false) }
        case .checkout:
            await runner.run(failure: "Branch nicht angelegt", note: "git switch -c") { try await $0.createBranch(name, at: start, checkout: true) }
        case .worktree(let path):
            await runner.run(failure: "Worktree nicht angelegt", note: "git worktree add -b") { try await $0.addWorktree(at: path, commit: start, newBranch: name) }
        }
    }
}
