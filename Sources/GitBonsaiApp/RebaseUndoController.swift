import AppKit
import GitEngine

/// "Undo…" in the status line after an interactive rebase of the app has finished. It resets the branch to `ORIG_HEAD` after asking, and is offered only while HEAD is still where the rebase left it.
@MainActor
final class RebaseUndoController {
    let button = NSButton(title: String(localized: "rebase.undo.button", defaultValue: "Undo…", bundle: .module, comment: "Status line button that asks to undo the last rebase."), target: nil, action: nil)
    private let viewModel: GraphViewModel
    private let prompter: ActionPrompter
    private var undo: RebaseUndo?
    /// Each update starts a new check; only the latest one may change the button.
    private var generation = 0

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.font = Theme.caption
        button.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(pressed)
        button.isHidden = true
    }

    /// Picks up a rebase git has finished since, and checks whether the last one can still be undone; called on every refresh of the tab.
    func update() {
        generation += 1
        let current = generation
        let repository = viewModel.repository
        Task {
            _ = await repository.finishedInteractiveRebase()
            let last = await repository.lastRebaseUndo()
            guard current == generation else { return }
            undo = last
            show()
        }
    }

    private func show() {
        button.isHidden = undo == nil
        guard let undo else { return }
        let sha = String(undo.before.prefix(RefString.shortSHA))
        button.toolTip = String(localized: "rebase.undo.toolTip", defaultValue: "Resets \(undo.shortBranch ?? "HEAD") to where it was before the rebase (ORIG_HEAD \(sha))", bundle: .module)
    }

    @objc private func pressed() {
        guard let undo else { return }
        let branch = undo.shortBranch.map(RefName.branch) ?? "HEAD"
        let before = RefName.commit(undo.before)
        let stacked = undo.stacked.compactMap { $0.after == nil ? nil : $0.ref.replacingOccurrences(of: "refs/heads/", with: "") }
        let info: LocalizedStringResource = if stacked.isEmpty {
            LocalizedStringResource("rebase.undo.info", defaultValue: "\(branch) goes back to \(before), where it was before the rebase (git reset --keep ORIG_HEAD). Local changes stay.", bundle: .module)
        } else {
            LocalizedStringResource("rebase.undo.infoWithBranches", defaultValue: "\(branch) goes back to \(before), where it was before the rebase (git reset --keep ORIG_HEAD). Local changes stay.\n\nBranches moved along go back as well: \(stacked.map(RefName.branch).joined(separator: ", ")).", bundle: .module)
        }
        Task {
            let confirmed = await ActionRunner(viewModel: viewModel, prompter: prompter).confirm(LocalizedStringResource("rebase.undo.title", defaultValue: "Undo Rebase?", bundle: .module), info: info, button: LocalizedStringResource("rebase.undo.confirm", defaultValue: "Undo Rebase", bundle: .module))
            guard confirmed else { return }
            self.undo = nil
            show()
            ActionRunner(viewModel: viewModel, prompter: prompter).run(failure: LocalizedStringResource("failure.rebase.notUndone", defaultValue: "Rebase not undone", bundle: .module), note: "git reset --keep ORIG_HEAD") { try await $0.undoRebase(undo) }
        }
    }
}
