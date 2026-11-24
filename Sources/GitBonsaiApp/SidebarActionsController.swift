import AppKit
import GitEngine

/// The context menus of the sidebar and creating a branch: hands each subject to the controller of its kind and owns what they share.
@MainActor
final class SidebarActionsController {
    let branches: BranchActionsController
    let worktrees: WorktreeActionsController
    let newBranch: NewBranchController
    let remotes: RemoteActionsController

    /// `checkout` runs a checkout from the sidebar (a branch checked out elsewhere passes its worktree); `switchWorktree` moves the tab like a double click.
    init(context: RepositoryContext, branchPull: BranchPullController, fastForward: FastForwardController, checkout: @escaping (CheckoutTarget, _ worktreePath: String?) -> Void, switchWorktree: @escaping (String) -> Void) {
        branches = BranchActionsController(context: context, branchPull: branchPull, fastForward: fastForward, checkout: checkout)
        worktrees = WorktreeActionsController(context: context, switchWorktree: switchWorktree)
        newBranch = NewBranchController(context: context)
        remotes = RemoteActionsController(context: context)
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

extension ActionRunner {
    /// Deletes a local branch without asking, undoable from the status line; when git refuses it as unmerged, asks before deleting it anyway.
    func deleteBranch(_ name: String) async {
        let question = ForceQuestion(title: LocalizedStringResource("branch.deleteUnmerged.title", defaultValue: "Delete unmerged Branch?", bundle: .module), names: RefString(marked: RefName.branch(name)), info: LocalizedStringResource("branch.deleteUnmerged.info", defaultValue: "The branch has commits that are not merged anywhere.", bundle: .module), button: LocalizedStringResource("branch.deleteUnmerged.confirm", defaultValue: "Delete anyway", bundle: .module))
        await performOrForce(failure: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module), note: "git branch -d", forcedNote: "git branch -D", undo: .branch(name), refusedBecause: \.isUnmergedBranch, question: question) { try await $0.deleteBranch(name, force: $1) }
    }

    /// Removes a worktree; when git refuses it for modified or untracked files, offers to remove it anyway. True when it is gone.
    func removeWorktree(at path: String) async -> Bool {
        let question = ForceQuestion(title: LocalizedStringResource("worktree.removeDirty.title", defaultValue: "Remove Worktree with Changes?", bundle: .module), names: RefString(marked: RefName.worktree((path as NSString).lastPathComponent)), button: LocalizedStringResource("worktree.removeDirty.confirm", defaultValue: "Remove anyway", bundle: .module))
        return await performOrForce(failure: LocalizedStringResource("failure.worktree.notRemoved", defaultValue: "Worktree not removed", bundle: .module), note: "git worktree remove", forcedNote: "git worktree remove --force", refusedBecause: \.isDirtyWorktree, question: question) { try await $0.removeWorktree(at: path, force: $1) }
    }
}

extension GraphViewModel {
    /// Where a new worktree goes by default: next to the main worktree, named after the repository and `suffix`.
    func defaultWorktreePath(suffix: String) -> String {
        let main = worktrees.first { $0.worktree.isMain }?.worktree.path ?? repository.path
        let parent = (main as NSString).deletingLastPathComponent
        let name = suffix.replacingOccurrences(of: "/", with: "-")
        return (parent as NSString).appendingPathComponent("\(repositoryName)-\(name)")
    }
}
