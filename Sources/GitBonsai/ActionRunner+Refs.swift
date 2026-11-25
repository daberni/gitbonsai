import AppKit
import GitEngine

extension ActionRunner {
    /// Deletes a local branch without asking, undoable from the status line; when git refuses it as unmerged, asks before deleting it anyway.
    func deleteBranch(_ name: String) async {
        let question = ForceQuestion(title: LocalizedStringResource("branch.deleteUnmerged.title", defaultValue: "Delete Branch?", bundle: .module), names: RefString(marked: RefName.branch(name)), info: LocalizedStringResource("branch.deleteUnmerged.info", defaultValue: "The branch has unmerged changes.", bundle: .module), button: LocalizedStringResource("branch.deleteUnmerged.confirm", defaultValue: "Delete anyway", bundle: .module))
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
