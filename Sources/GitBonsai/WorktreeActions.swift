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

    /// In the shared group order: go there (switch, Finder, terminal) | remove | change (lock).
    /// The worktree shown in this tab is not removed from here, the tab would lose its folder: its Remove stays disabled. The main worktree cannot be locked or removed.
    /// A worktree whose folder is gone offers only Remove, which drops git's record of it.
    func groups(for info: WorktreeInfo, isCurrent: Bool) -> [[MenuEntry]] {
        let worktree = info.worktree
        let path = worktree.path
        guard !worktree.isPrunable else {
            return [[MenuEntry(LocalizedStringResource("worktree.menu.removeMissing", defaultValue: "Remove", bundle: .module, comment: "Removes a worktree whose folder is gone; asks nothing.")) { [weak self] in self?.removeMissing(worktree) }]]
        }
        var goThere: [MenuEntry] = []
        if !isCurrent, !worktree.isBare {
            goThere.append(MenuEntry(LocalizedStringResource("worktree.menu.switch", defaultValue: "Switch to this Worktree", bundle: .module)) { [weak self] in self?.onSwitchWorktree?(path) }.movingHead)
        }
        goThere.append(MenuEntry(LocalizedStringResource("common.showInFinder", defaultValue: "Show in Finder", bundle: .module)) { ExternalApps.reveal([URL(fileURLWithPath: path)]) })
        goThere.append(MenuEntry(LocalizedStringResource("command.openTerminal.title", defaultValue: "Open in Terminal", bundle: .module)) { [weak self] in self?.openInTerminal(path) })
        var remove: [MenuEntry] = []
        var change: [MenuEntry] = []
        if !worktree.isMain {
            let currentReason = isCurrent ? String(localized: "worktree.menu.currentlyOpen", defaultValue: "Currently open", bundle: .module, comment: "Why the worktree shown in this tab cannot be removed.") : nil
            remove.append(.action(LocalizedStringResource("worktree.menu.remove", defaultValue: "Remove…", bundle: .module), disabledBecause: currentReason) { [weak self] in self?.remove(worktree) })
            change.append(worktree.isLocked
                ? MenuEntry(LocalizedStringResource("worktree.menu.unlock", defaultValue: "Unlock", bundle: .module)) { [weak self] in self?.unlock(path) }
                : MenuEntry(LocalizedStringResource("worktree.menu.lock", defaultValue: "Lock…", bundle: .module)) { [weak self] in self?.lock(path) })
        }
        return [goThere, remove, change]
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

    /// Only git's record is left; `--force` removes it without touching other missing worktrees, as a prune would. A locked one asks first, since the lock was meant to keep it, and needs `-f -f`.
    private func removeMissing(_ worktree: Worktree) {
        let path = worktree.path
        Task {
            if worktree.isLocked {
                let info: LocalizedStringResource = worktree.lockReason.map { reason -> LocalizedStringResource in LocalizedStringResource("worktree.removeLocked.infoReason", defaultValue: "Its folder is gone, but it is locked: \(reason)", bundle: .module) } ?? LocalizedStringResource("worktree.removeLocked.info", defaultValue: "Its folder is gone, but it is locked.", bundle: .module)
                guard await runner.confirm(LocalizedStringResource("worktree.removeLocked.title", defaultValue: "Remove locked Worktree?", bundle: .module), names: RefString(marked: RefName.worktree((path as NSString).lastPathComponent)), info: info, button: LocalizedStringResource("worktree.remove.confirm", defaultValue: "Remove", bundle: .module)) else { return }
            }
            let locked = worktree.isLocked
            await runner.perform(failure: LocalizedStringResource("failure.worktree.notRemoved", defaultValue: "Worktree not removed", bundle: .module), note: locked ? "git worktree remove -f -f" : "git worktree remove --force") { try await $0.removeWorktree(at: path, force: true, overridingLock: locked) }
        }
    }
}
