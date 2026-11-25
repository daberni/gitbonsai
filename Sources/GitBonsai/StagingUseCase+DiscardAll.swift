import AppKit
import GitEngine

extension StagingUseCase {
    /// What "Discard all" takes back: everything from the working directory's title and the history row, the unstaged changes from the Unstaged header and the command bar.
    enum DiscardScope {
        case everything, unstaged
    }

    /// Asks first, with a checkbox that adds the untracked files; those go to the Trash, not away for good, since git cannot bring them back.
    /// Conflicted files are left out of the unstaged scope; the whole scope puts them back to HEAD too, while the operation stays in progress.
    func discardAll(_ scope: DiscardScope) {
        guard let status = viewModel.status else { return }
        let tracked = status.entries.filter { !$0.isUntracked && !$0.isIgnored }
        let unstaged = tracked.filter { $0.conflict == nil && $0.worktreeState != .unmodified }.map(\.path)
        let count = scope == .everything ? tracked.count : unstaged.count
        let untracked = status.entries.filter(\.isUntracked).map(\.path)
        guard count > 0 || !untracked.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: scope == .everything ? LocalizedStringResource("files.discardAll.title", defaultValue: "Discard all Changes?", bundle: .module) : LocalizedStringResource("files.discardUnstaged.title", defaultValue: "Discard all unstaged Changes?", bundle: .module))
        alert.informativeText = String(localized: scope == .everything ? LocalizedStringResource("files.discardAll.info", defaultValue: "Staged and unstaged changes to \(count) files are lost.", bundle: .module) : LocalizedStringResource("files.discardUnstaged.info", defaultValue: "Unstaged changes to \(count) files are lost; staged changes stay.", bundle: .module))
        if !untracked.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "files.discardAll.includeUntracked", defaultValue: "Also move \(untracked.count) untracked files to the Trash", bundle: .module)
            alert.suppressionButton?.state = count == 0 ? .on : .off
        }
        let discard = alert.addButton(withTitle: String(localized: "common.discard", defaultValue: "Discard", bundle: .module))
        discard.hasDestructiveAction = true
        discard.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        cancel.keyEquivalent = "\r"
        let root = URL(fileURLWithPath: viewModel.repository.path)
        prompter.confirmDiscard(alert) { [weak self] in
            guard let self else { return }
            let trash = alert.suppressionButton?.state == .on ? untracked.map { root.appendingPathComponent($0) } : []
            let note = scope == .everything ? "git restore --source=HEAD --staged --worktree -- :/" : "git restore --worktree -- …"
            runner.run(failure: LocalizedStringResource("failure.files.notDiscarded", defaultValue: "Changes not discarded", bundle: .module), note: note, then: { [weak self] in self?.onChange?() }) { repository in
                if scope == .everything, count > 0 {
                    try await repository.discardAllChanges()
                } else {
                    try await repository.discardUnstagedChanges(unstaged)
                }
                for file in trash { try FileManager.default.trashItem(at: file, resultingItemURL: nil) }
            }
        }
    }
}
