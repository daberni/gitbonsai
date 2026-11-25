import AppKit
import GitEngine

/// What one action runs in: the repository its write goes to, an undo point around it, and the refresh afterwards. `GraphViewModel` provides it for its tab.
@MainActor
protocol ActionContext: AnyObject, Sendable {
    var repository: Repository { get }
    func withUndoPoint<T>(scope: UndoScope?, operation: String, _ body: () async throws -> T) async throws -> T
    func refresh(note: String?, focus: GraphViewModel.Focus) async
}

/// Runs one git write for a panel or toolbar action, refreshes the tab and reports a failure with git's message.
@MainActor
struct ActionRunner {
    let context: any ActionContext
    let prompter: any Prompting

    /// The tab is refreshed after a failure too: a conflicting apply or pop has changed the working tree.
    /// When local changes stopped the command before it changed anything, the failure offers to stash them, run it again and bring them back.
    /// `focus` is the history's selection after a successful run. `undo` names what a local operation may move, so the status line can offer to undo it.
    func run(failure: LocalizedStringResource, conflict: LocalizedStringResource? = nil, note: String, focus: GraphViewModel.Focus = .keepSelection, undo: UndoScope? = nil, then: (() -> Void)? = nil, _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        Task {
            await perform(failure: failure, conflict: conflict, note: note, focus: focus, undo: undo, then: then, operation)
            then?()
        }
    }

    /// `run` for a caller that waits for the outcome: returns the error so it can offer a way out, such as force; `report` false leaves telling the user to that caller.
    /// `then` runs after a retry with the changes stashed, which ends after this call.
    @discardableResult
    func perform(failure: LocalizedStringResource, conflict: LocalizedStringResource? = nil, note: String, focus: GraphViewModel.Focus = .keepSelection, report: Bool = true, undo: UndoScope? = nil, then: (() -> Void)? = nil, _ operation: @escaping @Sendable (Repository) async throws -> Void) async -> GitError? {
        let repository = context.repository
        do {
            try await context.withUndoPoint(scope: undo, operation: note) { try await operation(repository) }
            await context.refresh(note: note, focus: focus)
            return nil
        } catch {
            await context.refresh(note: nil, focus: .keepSelection)
            let gitError = error as? GitError
            if report {
                let stopped = gitError?.stoppedOnConflict == true
                let retry = GitFailureText.isBlockedByLocalChanges(error) ? [stashAndRetry(failure: failure, conflict: conflict, note: note, undo: undo, then: then, operation)] : []
                await prompter.reportUnlessStopped(error, title: stopped ? (conflict ?? failure) : failure, actions: retry, in: repository)
            }
            return gitError ?? GitError(arguments: [], exitCode: -1, stderr: error.localizedDescription)
        }
    }

    /// Runs the operation again with the local changes set aside. If they conflict on the way back, the working directory shows the conflicts and the stash stays; if the operation stops on conflicts itself, they wait in the stash.
    private func stashAndRetry(failure: LocalizedStringResource, conflict: LocalizedStringResource?, note: String, undo: UndoScope?, then: (() -> Void)?, _ operation: @escaping @Sendable (Repository) async throws -> Void) -> FailureAction {
        let message = String(localized: "stash.message.before", defaultValue: "GitBonsai: before \(note)", bundle: .module, comment: "Message of the stash that carries local changes past a command; the argument is the git command.")
        let prompter = prompter
        let carried = String(localized: "stash.message.carriedAlong", defaultValue: "\(note) · local changes carried along in a stash", bundle: .module, comment: "Status line after a command ran with the local changes stashed around it; the argument is the git command.")
        return FailureAction(title: LocalizedStringResource("failure.action.stashAndRetry", defaultValue: "Stash changes and try again", bundle: .module)) {
            run(failure: failure, conflict: conflict, note: carried, undo: undo, then: then) { repository in
                let conflicted = try await repository.withLocalChangesStashed(message: message) { try await operation(repository) }
                if conflicted { await prompter.reportConflictingReturn(of: message) }
            }
        }
    }

    /// Runs a write that git may refuse for a reason the user can override, such as an unmerged branch or a worktree with changes: on that refusal it asks with `question`, then runs the forced variant.
    /// Any other failure is reported. True when the write went through.
    @discardableResult
    func performOrForce(failure: LocalizedStringResource, note: String, forcedNote: String, undo: UndoScope? = nil, refusedBecause isRefusal: (GitError) -> Bool, question: ForceQuestion, _ operation: @escaping @Sendable (Repository, _ force: Bool) async throws -> Void) async -> Bool {
        guard let error = await perform(failure: failure, note: note, report: false, undo: undo, { try await operation($0, false) }) else { return true }
        guard isRefusal(error) else {
            prompter.report(error, title: failure)
            return false
        }
        guard await confirm(question.title, names: question.names, info: question.info, button: question.button) else { return false }
        return await perform(failure: failure, note: forcedNote, undo: undo) { try await operation($0, true) } == nil
    }

    /// What `performOrForce` asks before it overrides git's refusal; the button is destructive.
    struct ForceQuestion {
        let title: LocalizedStringResource
        let names: RefString
        var info: LocalizedStringResource?
        let button: LocalizedStringResource
    }

    /// A question with a confirm button and Cancel; `destructive` marks the confirm button red. `names` are the refs it acts on, shown as full pills between the short title and `info`.
    func confirm(_ title: LocalizedStringResource, names: RefString? = nil, info: LocalizedStringResource? = nil, button: LocalizedStringResource, destructive: Bool = true, style: NSAlert.Style = .warning) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = style
        if let names { alert.setConfirmation(title, names: names, info: info.map(RefString.init) ?? RefString(verbatim: "")) } else { alert.setText(RefString(title), info: info.map(RefString.init) ?? RefString(verbatim: "")) }
        alert.addButton(withTitle: button.text)
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
        alert.buttons.first?.hasDestructiveAction = destructive
        return await prompter.confirm(alert)
    }
}
