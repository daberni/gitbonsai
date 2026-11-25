import AppKit
import GitEngine

/// What the menu of a worktree in the sidebar offers, and running it.
@MainActor
final class WorktreeActions {
    private let runner: ActionRunner
    private let prompter: any Prompting
    private let settings: AppSettings
    /// Moves the tab to another worktree, like a double click on it in the sidebar.
    var onSwitchWorktree: ((String) -> Void)?

    init(context: RepositoryContext) {
        runner = context.runner
        prompter = context.prompter
        settings = context.settings
    }

    /// In the shared group order: go there (switch, Finder, terminal) | remove | change (lock); Prune comes last on its own, since it acts on all worktrees.
    /// The worktree shown in this tab is not removed from here: the tab would lose its folder. The main worktree cannot be locked or removed.
    func groups(for info: WorktreeInfo, isCurrent: Bool) -> [[MenuEntry]] {
        let worktree = info.worktree
        let path = worktree.path
        let exists = !worktree.isPrunable
        var goThere: [MenuEntry] = []
        if !isCurrent, exists, !worktree.isBare {
            goThere.append(MenuEntry(LocalizedStringResource("worktree.menu.switch", defaultValue: "Switch to this Worktree", bundle: .module)) { [weak self] in self?.onSwitchWorktree?(path) })
        }
        if exists {
            goThere.append(MenuEntry(LocalizedStringResource("common.showInFinder", defaultValue: "Show in Finder", bundle: .module)) { ExternalApps.reveal([URL(fileURLWithPath: path)]) })
            goThere.append(MenuEntry(LocalizedStringResource("command.openTerminal.title", defaultValue: "Open in terminal", bundle: .module)) { [weak self] in self?.openInTerminal(path) })
        }
        var remove: [MenuEntry] = []
        var change: [MenuEntry] = []
        if !worktree.isMain {
            if !isCurrent {
                remove.append(MenuEntry(LocalizedStringResource("worktree.menu.remove", defaultValue: "Remove…", bundle: .module)) { [weak self] in self?.remove(worktree) })
            }
            change.append(worktree.isLocked
                ? MenuEntry(LocalizedStringResource("worktree.menu.unlock", defaultValue: "Unlock", bundle: .module)) { [weak self] in self?.unlock(path) }
                : MenuEntry(LocalizedStringResource("worktree.menu.lock", defaultValue: "Lock…", bundle: .module)) { [weak self] in self?.lock(path) })
        }
        let pruneGroup: [MenuEntry] = [MenuEntry(LocalizedStringResource("worktree.menu.prune", defaultValue: "Prune missing Worktrees", bundle: .module)) { [weak self] in self?.prune() }]
        return [goThere, remove, change, pruneGroup]
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
