import AppKit
import GitEngine

/// The "New Branch" sheet of the Local header's plus and the toolbar's Branch button, and as "New Worktree" the sheet of the Worktrees header's plus: loads what the picker offers, shows the sheet and runs git with the answer.
@MainActor
final class CreateBranchUseCase {
    private let runner: ActionRunner
    private let prompter: any Prompting
    private let viewModel: GraphViewModel
    /// The sheet while it is open.
    private(set) var sheet: NewBranchSheet?
    /// From the click until the sheet closes, including the reads before it appears, so a second click does not open a second sheet.
    private var isOpen = false


    init(context: RepositoryContext) {
        viewModel = context.model
        runner = context.runner
        prompter = context.prompter
    }

    /// Where a new branch starts when the sheet opens: a commit selected in the history, or a ref from its menu.
    enum Start {
        case commit(Commit)
        case ref(String)
    }

    /// A commit start is offered under "Current" next to HEAD and preselected; a ref start preselects that ref; HEAD when nil.
    func show(start: Start? = nil, worktree: Bool = false) {
        guard !isOpen, let parent = prompter.window else { return }
        isOpen = true
        let repository = viewModel.repository
        Task {
            defer { isOpen = false }
            let tips = (try? await repository.refTips()) ?? []
            let headBranch = viewModel.refs.first { $0.kind == .localBranch && $0.isHead }?.name
            let headCommit = await repository.commitSummary("HEAD")
            var current: [RefCatalog.Item] = headCommit.map { [.head(branch: headBranch, commit: $0)] } ?? []
            var picked: RefCatalog.Item?
            if case .commit(let commit) = start {
                picked = .commit(CommitSummary(sha: commit.id, date: commit.committerDate, subject: commit.subject))
                current.append(picked!)
            }
            let catalog = RefCatalog(tips: tips, current: current)
            if case .ref(let name) = start { picked = catalog.item(titled: name) }
            let existing = Set(tips.filter { $0.kind == .localBranch }.map(\.name))
            let checkedOut = Set(viewModel.worktrees.compactMap(\.worktree.branchName))
            let free = existing.subtracting(checkedOut)
            // A new worktree starts on the first branch it can check out as it is, otherwise on HEAD with a new branch.
            let firstFree = catalog.groups(matching: "").lazy.flatMap(\.matches).map(\.item).first { if case .localBranch = $0.kind { free.contains($0.revision) } else { false } }
            let picker = RefPicker(repository: repository)
            picker.setCatalog(catalog, selection: worktree ? firstFree ?? current.first : picked ?? current.first)
            let purpose: NewBranchViewController.Purpose = worktree ? .worktree(freeBranches: free) : .branch
            let form = NewBranchViewController(repository: repository, purpose: purpose, existingBranches: existing, picker: picker) { [viewModel] name in viewModel.defaultWorktreePath(suffix: name) }
            let sheet = NewBranchSheet(form: form)
            self.sheet = sheet
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
            await runner.perform(failure: LocalizedStringResource("failure.branch.notCreated", defaultValue: "Branch not created", bundle: .module), note: "git branch") { try await $0.createBranch(name, at: start, checkout: false) }
        case .checkout:
            await runner.perform(failure: LocalizedStringResource("failure.branch.notCreated", defaultValue: "Branch not created", bundle: .module), note: "git switch -c") { try await $0.createBranch(name, at: start, checkout: true) }
        case .worktree(let path) where name.isEmpty:
            await runner.perform(failure: LocalizedStringResource("failure.worktree.notCreated", defaultValue: "Worktree not created", bundle: .module), note: "git worktree add") { try await $0.addWorktree(at: path, branch: start) }
        case .worktree(let path):
            await runner.perform(failure: LocalizedStringResource("failure.worktree.notCreated", defaultValue: "Worktree not created", bundle: .module), note: "git worktree add -b") { try await $0.addWorktree(at: path, commit: start, newBranch: name) }
        }
    }
}
