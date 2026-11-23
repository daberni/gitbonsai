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
        Task {
            await perform(failure: failure, conflict: conflict, note: note, focus: focus, then: then, operation)
            then?()
        }
    }

    /// `run` for a caller that waits for the outcome: returns the error so it can offer a way out, such as force; `report` false leaves telling the user to that caller.
    /// `then` runs after a retry with the changes stashed, which ends after this call.
    @discardableResult
    func perform(failure: LocalizedStringResource, conflict: LocalizedStringResource? = nil, note: String, focus: GraphViewModel.Focus = .keepSelection, report: Bool = true, then: (() -> Void)? = nil, _ operation: @escaping @Sendable (Repository) async throws -> Void) async -> GitError? {
        let repository = viewModel.repository
        do {
            try await operation(repository)
            await viewModel.refresh(note: note, focus: focus)
            return nil
        } catch {
            await viewModel.refresh(note: nil)
            let gitError = error as? GitError
            if report {
                let stopped = gitError?.stoppedOnConflict == true
                let retry = GitFailureText.isBlockedByLocalChanges(error) ? [stashAndRetry(failure: failure, conflict: conflict, note: note, then: then, operation)] : []
                await prompter.report(error, title: stopped ? (conflict ?? failure) : failure, actions: retry, unlessStoppedIn: repository)
            }
            return gitError ?? GitError(arguments: [], exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// Runs the operation again with the local changes set aside. If they conflict on the way back, the working directory shows the conflicts and the stash stays; if the operation stops on conflicts itself, they wait in the stash.
    private func stashAndRetry(failure: LocalizedStringResource, conflict: LocalizedStringResource?, note: String, then: (() -> Void)?, _ operation: @escaping @Sendable (Repository) async throws -> Void) -> FailureAction {
        let message = String(localized: "stash.message.before", defaultValue: "GitBonsai: before \(note)", bundle: .module, comment: "Message of the stash that carries local changes past a command; the argument is the git command.")
        let prompter = prompter
        let carried = String(localized: "stash.message.carriedAlong", defaultValue: "\(note) · local changes carried along in a stash", bundle: .module, comment: "Status line after a command ran with the local changes stashed around it; the argument is the git command.")
        return FailureAction(title: LocalizedStringResource("failure.action.stashAndRetry", defaultValue: "Stash changes and try again", bundle: .module)) {
            run(failure: failure, conflict: conflict, note: carried, then: then) { repository in
                let conflicted = try await repository.withLocalChangesStashed(message: message) { try await operation(repository) }
                if conflicted { await prompter.reportConflictingReturn(of: message) }
            }
        }
    }

    /// A question with a confirm button and Cancel; `destructive` marks the confirm button red.
    func confirm(_ title: LocalizedStringResource, info: LocalizedStringResource, button: LocalizedStringResource, destructive: Bool = true, style: NSAlert.Style = .warning) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.setText(title, info: info)
        alert.addButton(withTitle: button.text)
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        alert.buttons.first?.hasDestructiveAction = destructive
        return await prompter.confirm(alert)
    }

    static func copy(_ text: String) {
        let pasteboard = ScreenshotHarness.pasteboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
