import AppKit
import GitEngine

/// Runs one git write for a panel or toolbar action, refreshes the tab and reports a failure with git's message.
@MainActor
struct ActionRunner {
    let viewModel: GraphViewModel
    let prompter: ActionPrompter

    /// The tab is refreshed after a failure too: a conflicting apply or pop has changed the working tree.
    /// When local changes stopped the command before it changed anything, the failure offers to stash them, run it again and bring them back.
    /// `focus` is the history's selection after a successful run.
    func run(failure: LocalizedStringResource, conflict: LocalizedStringResource? = nil, note: String, focus: GraphViewModel.Focus = .keepSelection, then: (() -> Void)? = nil, _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        let repository = viewModel.repository
        let viewModel = viewModel
        let prompter = prompter
        Task {
            do {
                try await operation(repository)
                await viewModel.refresh(note: note, focus: focus)
            } catch {
                await viewModel.refresh(note: nil)
                let stopped = (error as? GitError)?.stoppedOnConflict == true
                let retry = GitFailureText.isBlockedByLocalChanges(error) ? [stashAndRetry(failure: failure, conflict: conflict, note: note, then: then, operation)] : []
                await prompter.report(error, title: stopped ? (conflict ?? failure) : failure, actions: retry, unlessStoppedIn: repository)
            }
            then?()
        }
    }

    /// Runs the operation again with the local changes set aside. If they conflict on the way back, the working directory shows the conflicts and the stash stays; if the operation stops on conflicts itself, they wait in the stash.
    private func stashAndRetry(failure: LocalizedStringResource, conflict: LocalizedStringResource?, note: String, then: (() -> Void)?, _ operation: @escaping @Sendable (Repository) async throws -> Void) -> FailureAction {
        let message = String(localized: "GitBonsai: before \(note)", bundle: .module, comment: "Message of the stash that carries local changes past a command; the argument is the git command.")
        let prompter = prompter
        let carried = String(localized: "\(note) · local changes carried along in a stash", bundle: .module, comment: "Status line after a command ran with the local changes stashed around it; the argument is the git command.")
        return FailureAction(title: "Stash changes and try again") {
            run(failure: failure, conflict: conflict, note: carried, then: then) { repository in
                let conflicted = try await repository.withLocalChangesStashed(message: message) { try await operation(repository) }
                if conflicted { await prompter.reportConflictingReturn(of: message) }
            }
        }
    }

    /// A yes-or-no question with a destructive first button.
    func confirm(_ title: LocalizedStringResource, info: LocalizedStringResource, button: LocalizedStringResource) async -> Bool {
        let alert = NSAlert()
        alert.setText(title, info: info)
        alert.addButton(withTitle: button.text)
        alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
        alert.buttons.first?.hasDestructiveAction = true
        return await prompter.confirm(alert)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
