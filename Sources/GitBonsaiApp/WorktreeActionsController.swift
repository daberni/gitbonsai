import AppKit
import GitEngine

/// The context menu of a worktree in the sidebar, and running its actions.
@MainActor
final class WorktreeActionsController {
    private let runner: ActionRunner
    private let prompter: any Prompting
    private let settings: AppSettings
    private let switchWorktree: (String) -> Void

    init(context: RepositoryContext, switchWorktree: @escaping (String) -> Void) {
        runner = context.runner
        prompter = context.prompter
        settings = context.settings
        self.switchWorktree = switchWorktree
    }

    /// The worktree shown in this tab is not removed from here: the tab would lose its folder. The main worktree cannot be locked or removed.
    func menuGroups(for info: WorktreeInfo, isCurrent: Bool) -> [[NSMenuItem]] {
        let worktree = info.worktree
        let path = worktree.path
        let exists = !worktree.isPrunable
        var switchGroup: [NSMenuItem] = []
        if !isCurrent, exists, !worktree.isBare {
            switchGroup.append(ActionMenuItem(LocalizedStringResource("worktree.menu.switch", defaultValue: "Switch to this Worktree", bundle: .module)) { [weak self] in self?.switchWorktree(path) })
        }
        let openGroup: [NSMenuItem] = exists ? [
            ActionMenuItem(LocalizedStringResource("common.showInFinder", defaultValue: "Show in Finder", bundle: .module)) { ExternalApps.reveal([URL(fileURLWithPath: path)]) },
            ActionMenuItem(LocalizedStringResource("command.openTerminal.title", defaultValue: "Open in terminal", bundle: .module)) { [weak self] in self?.openInTerminal(path) },
        ] : []
        var manageGroup: [NSMenuItem] = []
        if !worktree.isMain {
            manageGroup.append(worktree.isLocked
                ? ActionMenuItem(LocalizedStringResource("worktree.menu.unlock", defaultValue: "Unlock", bundle: .module)) { [weak self] in self?.unlock(path) }
                : ActionMenuItem(LocalizedStringResource("worktree.menu.lock", defaultValue: "Lock…", bundle: .module)) { [weak self] in self?.lock(path) })
            if !isCurrent {
                manageGroup.append(ActionMenuItem(LocalizedStringResource("worktree.menu.remove", defaultValue: "Remove…", bundle: .module)) { [weak self] in self?.remove(worktree) })
            }
        }
        let pruneGroup: [NSMenuItem] = [ActionMenuItem(LocalizedStringResource("worktree.menu.prune", defaultValue: "Prune missing Worktrees", bundle: .module)) { [weak self] in self?.prune() }]
        return [switchGroup, openGroup, manageGroup, pruneGroup]
    }

    // MARK: Actions

    private func openInTerminal(_ path: String) {
        ExternalApps.openInTerminal(URL(fileURLWithPath: path, isDirectory: true), settings: settings)
    }

    private func lock(_ path: String) {
        let form = ActionForm(title: LocalizedStringResource("worktree.lock.title", defaultValue: "Lock \(RefName.worktree((path as NSString).lastPathComponent))", bundle: .module), confirm: LocalizedStringResource("worktree.lock.confirm", defaultValue: "Lock", bundle: .module))
        form.addField(key: "reason", label: LocalizedStringResource("worktree.lock.reason", defaultValue: "Reason (optional)", bundle: .module), required: false)
        Task {
            guard let values = await prompter.ask(form) else { return }
            let reason = values.value("reason")
            await runner.perform(failure: LocalizedStringResource("failure.worktree.notLocked", defaultValue: "Worktree not locked", bundle: .module), note: "git worktree lock") { try await $0.lockWorktree(at: path, reason: reason) }
        }
    }

    private func unlock(_ path: String) {
        Task { await runner.perform(failure: LocalizedStringResource("failure.worktree.notUnlocked", defaultValue: "Worktree not unlocked", bundle: .module), note: "git worktree unlock") { try await $0.unlockWorktree(at: path) } }
    }

    /// Asks first, with the choice to delete the worktree's branch as well; the branch goes only once the worktree is gone.
    private func remove(_ worktree: Worktree) {
        let folder = (worktree.path as NSString).lastPathComponent
        let form = ActionForm(title: LocalizedStringResource("worktree.remove.title", defaultValue: "Remove Worktree?", bundle: .module), names: RefString(marked: RefName.worktree(folder)), confirm: LocalizedStringResource("worktree.remove.confirm", defaultValue: "Remove", bundle: .module))
        if let branch = worktree.branchName { form.addCheckbox(LocalizedStringResource("worktree.remove.deleteBranch", defaultValue: "Also delete branch \(RefName.branch(branch))", bundle: .module), checked: false) }
        form.alert.buttons.first?.hasDestructiveAction = true
        Task {
            guard let values = await prompter.ask(form) else { return }
            guard await runner.removeWorktree(at: worktree.path) else { return }
            if values.isChecked, let branch = worktree.branchName { await runner.deleteBranch(branch) }
        }
    }

    private func prune() {
        Task { await runner.perform(failure: LocalizedStringResource("failure.worktree.pruneFailed", defaultValue: "Pruning failed", bundle: .module), note: "git worktree prune") { try await $0.pruneWorktrees() } }
    }
}
