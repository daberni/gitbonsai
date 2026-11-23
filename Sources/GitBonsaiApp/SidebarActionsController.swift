import AppKit
import GitEngine

/// The context menus of the sidebar and creating a branch: hands each subject to the controller of its kind and owns what they share.
@MainActor
final class SidebarActionsController {
    let prompter = ActionPrompter()
    let branches: BranchActionsController
    let worktrees: WorktreeActionsController
    let newBranch: NewBranchController
    let remotes: RemoteActionsController

    /// `checkout` runs a checkout from the sidebar (a branch checked out elsewhere passes its worktree); `switchWorktree` moves the tab like a double click.
    init(viewModel: GraphViewModel, branchPull: BranchPullController, fastForward: FastForwardController, checkout: @escaping (CheckoutTarget, _ worktreePath: String?) -> Void, switchWorktree: @escaping (String) -> Void) {
        let runner = SidebarActionRunner(viewModel: viewModel, prompter: prompter)
        branches = BranchActionsController(runner: runner, branchPull: branchPull, fastForward: fastForward, checkout: checkout)
        worktrees = WorktreeActionsController(runner: runner, switchWorktree: switchWorktree)
        newBranch = NewBranchController(runner: runner)
        remotes = RemoteActionsController(runner: runner)
    }

    func menuItems(for subject: SidebarMenuSubject) -> [NSMenuItem] {
        let groups = switch subject {
        case .branch(let ref): branches.sections(for: ref).groups
        case .worktree(let info, let isCurrent): worktrees.menuGroups(for: info, isCurrent: isCurrent)
        case .remote(let name): remotes.menuGroups(for: name)
        }
        return groups.joinedWithSeparators
    }
}

extension Array where Element == [NSMenuItem] {
    /// The non-empty groups in order, with a separator between neighbours.
    var joinedWithSeparators: [NSMenuItem] {
        filter { !$0.isEmpty }.enumerated().flatMap { offset, group in (offset > 0 ? [NSMenuItem.separator()] : []) + group }
    }
}

/// The sidebar's questions around git writes that `ActionRunner` runs: delete or remove anyway, and where a new worktree goes.
@MainActor
final class SidebarActionRunner {
    let viewModel: GraphViewModel
    let prompter: ActionPrompter
    private var actions: ActionRunner { ActionRunner(viewModel: viewModel, prompter: prompter) }

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
    }

    @discardableResult
    func run(failure: LocalizedStringResource, conflict: LocalizedStringResource? = nil, note: String, report: Bool = true, undo: UndoScope? = nil, _ operation: @escaping @Sendable (Repository) async throws -> Void) async -> GitError? {
        await actions.perform(failure: failure, conflict: conflict, note: note, report: report, undo: undo, operation)
    }

    func confirm(_ title: LocalizedStringResource, names: RefString? = nil, info: LocalizedStringResource? = nil, button: LocalizedStringResource, destructive: Bool = false, style: NSAlert.Style = .informational) async -> Bool {
        await actions.confirm(title, names: names, info: info, button: button, destructive: destructive, style: style)
    }

    /// Deletes a local branch without asking, undoable from the status line; when git refuses it as unmerged, asks before deleting it anyway.
    func deleteBranch(_ name: String) async {
        guard let error = await run(failure: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module), note: "git branch -d", report: false, undo: .branch(name), { try await $0.deleteBranch(name, force: false) }) else { return }
        guard error.isUnmergedBranch else {
            prompter.report(error, title: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module))
            return
        }
        guard await confirm(LocalizedStringResource("branch.deleteUnmerged.title", defaultValue: "Delete unmerged Branch?", bundle: .module), names: RefString(marked: RefName.branch(name)), button: LocalizedStringResource("branch.deleteUnmerged.confirm", defaultValue: "Delete anyway", bundle: .module), destructive: true, style: .warning) else { return }
        await run(failure: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module), note: "git branch -D", undo: .branch(name)) { try await $0.deleteBranch(name, force: true) }
    }

    /// Removes a worktree; when git refuses it for modified or untracked files, shows git's message and offers to remove it anyway. True when it is gone.
    func removeWorktree(at path: String) async -> Bool {
        guard let error = await run(failure: LocalizedStringResource("failure.worktree.notRemoved", defaultValue: "Worktree not removed", bundle: .module), note: "git worktree remove", report: false, { try await $0.removeWorktree(at: path, force: false) }) else { return true }
        guard error.isDirtyWorktree else {
            prompter.report(error, title: LocalizedStringResource("failure.worktree.notRemoved", defaultValue: "Worktree not removed", bundle: .module))
            return false
        }
        let name = (path as NSString).lastPathComponent
        guard await confirm(LocalizedStringResource("worktree.removeDirty.title", defaultValue: "Remove Worktree with Changes?", bundle: .module), names: RefString(marked: RefName.worktree(name)), button: LocalizedStringResource("worktree.removeDirty.confirm", defaultValue: "Remove anyway", bundle: .module), destructive: true, style: .warning) else { return false }
        return await run(failure: LocalizedStringResource("failure.worktree.notRemoved", defaultValue: "Worktree not removed", bundle: .module), note: "git worktree remove --force") { try await $0.removeWorktree(at: path, force: true) } == nil
    }

    /// Next to the main worktree, named after the repository and `suffix`.
    func defaultWorktreePath(suffix: String) -> String {
        let main = viewModel.worktrees.first { $0.worktree.isMain }?.worktree.path ?? viewModel.repository.path
        let parent = (main as NSString).deletingLastPathComponent
        let name = suffix.replacingOccurrences(of: "/", with: "-")
        return (parent as NSString).appendingPathComponent("\(viewModel.repositoryName)-\(name)")
    }
}
