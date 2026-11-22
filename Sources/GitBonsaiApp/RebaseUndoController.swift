import AppKit
import GitEngine

/// "Rückgängig" in the status line after an interactive rebase of the app has finished. It resets the branch to `ORIG_HEAD` after asking, and is offered only while HEAD is still where the rebase left it.
@MainActor
final class RebaseUndoController {
    let button = NSButton(title: "Rückgängig", target: nil, action: nil)
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
        let branch = undo.shortBranch.map { "„\($0)“" } ?? "HEAD"
        button.toolTip = "Setzt \(branch) auf den Stand vor dem Rebase zurück (ORIG_HEAD \(undo.before.prefix(7)))"
    }

    @objc private func pressed() {
        guard let undo else { return }
        let branch = undo.shortBranch.map { "„\($0)“" } ?? "HEAD"
        let stacked = undo.stacked.compactMap { $0.after == nil ? nil : $0.ref.replacingOccurrences(of: "refs/heads/", with: "") }
        var info = "\(branch) kommt zurück auf \(undo.before.prefix(7)), den Stand vor dem Rebase (git reset --keep ORIG_HEAD). Lokale Änderungen bleiben."
        if !stacked.isEmpty { info += "\n\nMitgezogene Branches gehen ebenfalls zurück: " + stacked.joined(separator: ", ") + "." }
        Task {
            let confirmed = await ActionRunner(viewModel: viewModel, prompter: prompter).confirm("Rebase rückgängig machen?", info: info, button: "Rückgängig machen")
            guard confirmed else { return }
            self.undo = nil
            show()
            ActionRunner(viewModel: viewModel, prompter: prompter).run(failure: "Rebase nicht rückgängig gemacht", note: "git reset --keep ORIG_HEAD") { try await $0.undoRebase(undo) }
        }
    }
}
