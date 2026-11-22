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
            switchGroup.append(ActionMenuItem("Zu diesem Worktree wechseln") { [weak self] in self?.switchWorktree(path) })
        }
        let openGroup: [NSMenuItem] = exists ? [
            ActionMenuItem("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) },
            ActionMenuItem("Im Terminal öffnen") { Self.openInTerminal(path) },
        ] : []
        var manageGroup: [NSMenuItem] = []
        if !worktree.isMain {
            manageGroup.append(worktree.isLocked
                ? ActionMenuItem("Entsperren") { [weak self] in self?.unlock(path) }
                : ActionMenuItem("Sperren …") { [weak self] in self?.lock(path) })
            if !isCurrent {
                manageGroup.append(ActionMenuItem("Entfernen …") { [weak self] in self?.remove(worktree) })
            }
        }
        let pruneGroup: [NSMenuItem] = [ActionMenuItem("Fehlende Worktrees aufräumen") { [weak self] in self?.prune() }]
        return [switchGroup, openGroup, manageGroup, pruneGroup]
    }

    // MARK: Actions

    private static func openInTerminal(_ path: String) {
        ExternalApps.openInTerminal(URL(fileURLWithPath: path, isDirectory: true))
    }

    private func lock(_ path: String) {
        let form = ActionForm(title: "\(worktree: (path as NSString).lastPathComponent) sperren", info: "Ein gesperrter Worktree wird nicht aufgeräumt, verschoben oder entfernt, etwa wenn er auf einem Laufwerk liegt, das nicht immer angeschlossen ist.", confirm: "Sperren")
        form.addField(key: "reason", label: "Grund (optional)", required: false)
        Task {
            guard let values = await runner.prompter.ask(form) else { return }
            let reason = values.value("reason")
            await runner.run(failure: "Worktree nicht gesperrt", note: "git worktree lock") { try await $0.lockWorktree(at: path, reason: reason) }
        }
    }

    private func unlock(_ path: String) {
        Task { await runner.run(failure: "Worktree nicht entsperrt", note: "git worktree unlock") { try await $0.unlockWorktree(at: path) } }
    }

    /// Asks first, with the choice to delete the worktree's branch as well; the branch goes only once the worktree is gone.
    private func remove(_ worktree: Worktree) {
        let folder = (worktree.path as NSString).lastPathComponent
        let form = ActionForm(title: "Worktree \(worktree: folder) entfernen?", info: "Der Ordner \(path: (worktree.path as NSString).abbreviatingWithTildeInPath) wird gelöscht. Commits bleiben im Repository.", confirm: "Entfernen")
        if let branch = worktree.branchName { form.addCheckbox("Branch \(branch: branch) auch löschen", checked: false) }
        form.alert.buttons.first?.hasDestructiveAction = true
        Task {
            guard let values = await runner.prompter.ask(form) else { return }
            guard await runner.removeWorktree(at: worktree.path) else { return }
            if values.isChecked, let branch = worktree.branchName { await runner.deleteBranch(branch) }
        }
    }

    private func prune() {
        Task { await runner.run(failure: "Aufräumen fehlgeschlagen", note: "git worktree prune") { try await $0.pruneWorktrees() } }
    }
}
