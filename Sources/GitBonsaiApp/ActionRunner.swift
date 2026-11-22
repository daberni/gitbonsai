import AppKit
import GitEngine

/// Runs one git write for a panel or toolbar action, refreshes the tab and reports a failure with git's message.
@MainActor
struct ActionRunner {
    let viewModel: GraphViewModel
    let prompter: ActionPrompter

    /// The tab is refreshed after a failure too: a conflicting apply or pop has changed the working tree.
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
                await prompter.report(error, title: stopped ? (conflict ?? failure) : failure, unlessStoppedIn: repository)
            }
            then?()
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
