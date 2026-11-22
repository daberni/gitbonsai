import AppKit
import GitEngine

/// The context menu of a worktree in the sidebar, and running its actions.
@MainActor
final class WorktreeActionsController {
    private let runner: SidebarActionRunner
    private let switchWorktree: (String) -> Void

    init(runner: SidebarActionRunner, switchWorktree: @escaping (String) -> Void) {
        self.runner = runner
        self.switchWorktree = switchWorktree
    }

    /// The worktree shown in this tab is not removed from here: the tab would lose its folder. The main worktree cannot be locked or removed.
    func menuGroups(for info: WorktreeInfo, isCurrent: Bool) -> [[NSMenuItem]] {
        let worktree = info.worktree
        let path = worktree.path
        let exists = !worktree.isPrunable
        var switchGroup: [NSMenuItem] = []
        if !isCurrent, exists, !worktree.isBare {
            switchGroup.append(ActionMenuItem("Switch to This Worktree") { [weak self] in self?.switchWorktree(path) })
        }
        let openGroup: [NSMenuItem] = exists ? [
            ActionMenuItem("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            ActionMenuItem("Open in Terminal") { Self.openInTerminal(path) },
        ] : []
        var manageGroup: [NSMenuItem] = []
        if !worktree.isMain {
            manageGroup.append(worktree.isLocked
                ? ActionMenuItem("Unlock") { [weak self] in self?.unlock(path) }
                : ActionMenuItem("Lock…") { [weak self] in self?.lock(path) })
            if !isCurrent {
                manageGroup.append(ActionMenuItem("Remove…") { [weak self] in self?.remove(worktree) })
            }
        }
        let pruneGroup: [NSMenuItem] = [ActionMenuItem("Prune Missing Worktrees") { [weak self] in self?.prune() }]
        return [switchGroup, openGroup, manageGroup, pruneGroup]
    }

    // MARK: Actions

    private static func openInTerminal(_ path: String) {
        ExternalApps.openInTerminal(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func lock(_ path: String) {
        let form = ActionForm(title: "Lock \(RefName.worktree((path as NSString).lastPathComponent))", info: "A locked worktree is not pruned, moved or removed, for example when it lives on a drive that is not always connected.", confirm: "Lock")
        form.addField(key: "reason", label: "Reason (optional)", required: false)
        Task {
            guard let values = await runner.prompter.ask(form) else { return }
            let reason = values.value("reason")
            await runner.run(failure: "Worktree not locked", note: "git worktree lock") { try await $0.lockWorktree(at: path, reason: reason) }
        }
    }

    private func unlock(_ path: String) {
        Task { await runner.run(failure: "Worktree not unlocked", note: "git worktree unlock") { try await $0.unlockWorktree(at: path) } }
    }

    /// Asks first, with the choice to delete the worktree's branch as well; the branch goes only once the worktree is gone.
    private func remove(_ worktree: Worktree) {
        let folder = (worktree.path as NSString).lastPathComponent
        let shownPath = (worktree.path as NSString).abbreviatingWithTildeInPath
        let form = ActionForm(title: "Remove Worktree \(RefName.worktree(folder))?", info: "The folder \(RefName.path(shownPath)) will be deleted. Commits stay in the repository.", confirm: "Remove")
        if let branch = worktree.branchName { form.addCheckbox("Also delete branch \(RefName.branch(branch))", checked: false) }
        form.alert.buttons.first?.hasDestructiveAction = true
        Task {
            guard let values = await runner.prompter.ask(form) else { return }
            guard await runner.removeWorktree(at: worktree.path) else { return }
            if values.isChecked, let branch = worktree.branchName { await runner.deleteBranch(branch) }
        }
    }

    private func prune() {
        Task { await runner.run(failure: "Pruning failed", note: "git worktree prune") { try await $0.pruneWorktrees() } }
    }
}
