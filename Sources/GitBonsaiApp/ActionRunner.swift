import AppKit
import GitEngine

/// Runs one git write for a panel or toolbar action, refreshes the tab and reports a failure with git's message.
@MainActor
struct ActionRunner {
    let viewModel: GraphViewModel
    let prompter: ActionPrompter

    /// The tab is refreshed after a failure too: a conflicting apply or pop has changed the working tree.
    /// When local changes stopped the command before it changed anything, the failure offers to stash them, run it again and bring them back.
    func run(failure: String, conflict: String? = nil, note: String, then: (() -> Void)? = nil, _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        let repository = viewModel.repository
        let viewModel = viewModel
        let prompter = prompter
        Task {
            do {
                try await operation(repository)
                await viewModel.refresh(note: note)
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
    private func stashAndRetry(failure: String, conflict: String?, note: String, then: (() -> Void)?, _ operation: @escaping @Sendable (Repository) async throws -> Void) -> FailureAction {
        let message = "GitBonsai: vor \(note)"
        let prompter = prompter
        return FailureAction(title: "Änderungen stashen und erneut versuchen") {
            run(failure: failure, conflict: conflict, note: note + " · lokale Änderungen per Stash mitgenommen", then: then) { repository in
                let conflicted = try await repository.withLocalChangesStashed(message: message) { try await operation(repository) }
                if conflicted { await prompter.reportConflictingReturn(of: message) }
            }
        }
    }

    /// A yes-or-no question with a destructive first button.
    func confirm(_ title: String, info: String, button: String) async -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Abbrechen")
        alert.buttons.first?.hasDestructiveAction = true
        return await prompter.confirm(alert)
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
