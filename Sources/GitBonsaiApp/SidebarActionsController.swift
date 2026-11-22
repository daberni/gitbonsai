import AppKit
import GitEngine

/// The context menus of the sidebar and creating a branch: hands each subject to the controller of its kind and owns what they share.
@MainActor
final class SidebarActionsController {
    let prompter = ActionPrompter()
    let branches: BranchActionsController
    let worktrees: WorktreeActionsController
    let newBranch: NewBranchController

    /// `checkout` runs a checkout from the sidebar (a branch checked out elsewhere passes its worktree); `switchWorktree` moves the tab like a double click.
    init(viewModel: GraphViewModel, branchPull: BranchPullController, checkout: @escaping (CheckoutTarget, _ worktreePath: String?) -> Void, switchWorktree: @escaping (String) -> Void) {
        let runner = SidebarActionRunner(viewModel: viewModel, prompter: prompter)
        branches = BranchActionsController(runner: runner, branchPull: branchPull, checkout: checkout)
        worktrees = WorktreeActionsController(runner: runner, switchWorktree: switchWorktree)
        newBranch = NewBranchController(runner: runner)
    }

    func menuItems(for subject: SidebarMenuSubject) -> [NSMenuItem] {
        let groups = switch subject {
        case .branch(let ref): branches.menuGroups(for: ref)
        case .worktree(let info, let isCurrent): worktrees.menuGroups(for: info, isCurrent: isCurrent)
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

/// Runs the git writes of the sidebar's actions, asks the questions around them and refreshes the tab.
@MainActor
final class SidebarActionRunner {
    let viewModel: GraphViewModel
    let prompter: ActionPrompter

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
    }

    /// Runs one git write and refreshes the tab, also after a failure: a stopped merge or rebase has changed the repository.
    /// Returns the error so a caller can offer a way out, such as force; `report` false leaves telling the user to that caller.
    @discardableResult
    func run(failure: LocalizedStringResource, conflict: LocalizedStringResource? = nil, note: String, report: Bool = true, _ operation: @Sendable (Repository) async throws -> Void) async -> GitError? {
        do {
            try await operation(viewModel.repository)
            await viewModel.refresh(note: note)
            return nil
        } catch {
            await viewModel.refresh(note: nil)
            let gitError = error as? GitError
            if report {
                let title = gitError?.stoppedOnConflict == true ? (conflict ?? failure) : failure
                await prompter.report(error, title: title, unlessStoppedIn: viewModel.repository)
            }
            return gitError ?? GitError(arguments: [], exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// A question with a confirm button and Cancel; `destructive` marks the confirm button red.
    func confirm(_ title: LocalizedStringResource, info: LocalizedStringResource, button: LocalizedStringResource, destructive: Bool = false, style: NSAlert.Style = .informational) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.setText(title, info: info)
        alert.addButton(withTitle: button.text)
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        alert.buttons.first?.hasDestructiveAction = destructive
        return await prompter.confirm(alert)
    }

    /// Deletes a local branch; when git refuses it as unmerged, shows git's message and offers to delete it anyway.
    func deleteBranch(_ name: String) async {
        guard let error = await run(failure: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module), note: "git branch -d", report: false, { try await $0.deleteBranch(name, force: false) }) else { return }
        guard error.isUnmergedBranch else {
            prompter.report(error, title: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module))
            return
        }
        let message = Self.gitMessage(error)
        guard await confirm(LocalizedStringResource("branch.deleteUnmerged.title", defaultValue: "\(RefName.branch(name)) is not fully merged", bundle: .module), info: LocalizedStringResource("branch.deleteUnmerged.info", defaultValue: "\(message)\n\nCommits that are only on this branch can then only be reached through the reflog.", bundle: .module), button: LocalizedStringResource("branch.deleteUnmerged.confirm", defaultValue: "Delete anyway", bundle: .module), destructive: true, style: .warning) else { return }
        await run(failure: LocalizedStringResource("failure.branch.notDeleted", defaultValue: "Branch not deleted", bundle: .module), note: "git branch -D") { try await $0.deleteBranch(name, force: true) }
    }

    /// Removes a worktree; when git refuses it for modified or untracked files, shows git's message and offers to remove it anyway. True when it is gone.
    func removeWorktree(at path: String) async -> Bool {
        guard let error = await run(failure: LocalizedStringResource("failure.worktree.notRemoved", defaultValue: "Worktree not removed", bundle: .module), note: "git worktree remove", report: false, { try await $0.removeWorktree(at: path, force: false) }) else { return true }
        guard error.isDirtyWorktree else {
            prompter.report(error, title: LocalizedStringResource("failure.worktree.notRemoved", defaultValue: "Worktree not removed", bundle: .module))
            return false
        }
        let name = (path as NSString).lastPathComponent
        let message = Self.gitMessage(error)
        guard await confirm(LocalizedStringResource("worktree.removeDirty.title", defaultValue: "\(RefName.worktree(name)) has uncommitted changes", bundle: .module), info: LocalizedStringResource("worktree.removeDirty.info", defaultValue: "\(message)\n\nThe changes and untracked files in this folder will be lost.", bundle: .module), button: LocalizedStringResource("worktree.removeDirty.confirm", defaultValue: "Remove anyway", bundle: .module), destructive: true, style: .warning) else { return false }
        return await run(failure: LocalizedStringResource("failure.worktree.notRemoved", defaultValue: "Worktree not removed", bundle: .module), note: "git worktree remove --force") { try await $0.removeWorktree(at: path, force: true) } == nil
    }

    /// git's own words, without the hint lines that suggest commands.
    static func gitMessage(_ error: GitError) -> String {
        error.stderr.split(separator: "\n").filter { !$0.hasPrefix("hint:") }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Next to the main worktree, named after the repository and `suffix`.
    func defaultWorktreePath(suffix: String) -> String {
        let main = viewModel.worktrees.first { $0.worktree.isMain }?.worktree.path ?? viewModel.repository.path
        let parent = (main as NSString).deletingLastPathComponent
        let name = suffix.replacingOccurrences(of: "/", with: "-")
        return (parent as NSString).appendingPathComponent("\(viewModel.repositoryName)-\(name)")
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
