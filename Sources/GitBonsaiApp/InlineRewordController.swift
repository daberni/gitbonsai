import AppKit
import GitEngine

/// Editing a commit's message in place in the detail panel, from the commit menu, a double click on the subject, the pencil or ⌘E.
/// Saving rewords through `Repository.reword`: HEAD alone by `git commit --amend --only`, anything else by the one-step interactive rebase. Undo stays in the status line.
@MainActor
final class InlineRewordController {
    private let viewModel: GraphViewModel
    private let prompter: ActionPrompter
    private let access: (Commit) -> InteractiveRebaseController.RewordAccess?
    private weak var detail: DetailView?
    /// The editor while it is open, for the harness.
    private(set) var editor: CommitMessageEditor?
    private var commit: Commit?
    private var plan: RebasePlan?
    private var hint: RefString?
    /// The commit was rewritten as `new`; the history keeps it selected across the reload that follows.
    var onRewritten: ((_ old: String, _ new: String) -> Void)?
    /// The editor closed, saved or cancelled; after saving the refresh is done and the panel shows whatever is selected now.
    var onClosed: (() -> Void)?

    init(viewModel: GraphViewModel, prompter: ActionPrompter, detail: DetailView, access: @escaping (Commit) -> InteractiveRebaseController.RewordAccess?) {
        self.viewModel = viewModel
        self.prompter = prompter
        self.detail = detail
        self.access = access
    }

    var isEditing: Bool { editor?.window != nil }

    /// Turns the header of the shown commit into the editor; refused with a beep where the commit menu disables the entry.
    func begin(_ commit: Commit) {
        guard !isEditing, let detail, access(commit) == .allowed else { return NSSound.beep() }
        let message = commit.body.isEmpty ? commit.subject : "\(commit.subject)\n\n\(commit.body)"
        let editor = CommitMessageEditor(message: message)
        editor.onSave = { [weak self] in self?.save() }
        editor.onCancel = { [weak self] in self?.cancel() }
        guard detail.beginEditingMessage(of: commit.id, with: editor) else { return NSSound.beep() }
        self.editor = editor
        self.commit = commit
        plan = nil
        editor.focus()
        Task { await prepare(commit, for: editor) }
    }

    func cancel() {
        guard let editor, !editor.isSaving else { return }
        self.editor = nil
        detail?.endEditingMessage()
        onClosed?()
    }

    /// Plans the reword and says what it rewrites, once git has answered.
    private func prepare(_ commit: Commit, for editor: CommitMessageEditor) async {
        let repository = viewModel.repository
        do {
            var plan = try await repository.singleStepPlan(.reword(""), commit: commit.id)
            let hasLocalChanges = viewModel.status?.entries.contains { !$0.isUntracked && !$0.isIgnored } ?? false
            let hasStaged = !(viewModel.status?.staged.isEmpty ?? true)
            plan.autostash = !plan.rewordsHeadAlone && hasLocalChanges
            let published = await repository.publishedCommitCount(rewrittenBy: plan.base)
            guard editor === self.editor else { return }
            self.plan = plan
            hint = CommitActionsController.publishedHint(published, upstream: viewModel.status?.branch.upstream)
            editor.showNote(Self.note(plan, published: published, upstream: viewModel.status?.branch.upstream, hasStaged: hasStaged))
            editor.canSave = true
        } catch {
            guard editor === self.editor else { return }
            let reason = (error as? RebasePlanError).map(InteractiveRebaseController.describe) ?? "\(error)"
            editor.showNote(RefString(reason))
        }
    }

    /// "Schreibt 3 Commits neu · 3 schon auf origin/develop", with what happens to uncommitted changes and branches that move along.
    static func note(_ plan: RebasePlan, published: Int, upstream: String?, hasStaged: Bool) -> RefString {
        let count = plan.steps.count
        var parts: [RefString] = ["Schreibt \(count == 1 ? "1 Commit" : "\(count) Commits") neu"]
        if published > 0 { parts.append("\(published) schon auf \(upstream.map { "\(remoteBranch: $0)" } ?? "dem Upstream")") }
        let moving = plan.branches.values.flatMap { $0 }.map { $0.replacingOccurrences(of: "refs/heads/", with: "") }.sorted()
        if !moving.isEmpty { parts.append("\(RefString.joined(moving.map { "\(branch: $0)" }, separator: ", ")) zieht mit") }
        if plan.rewordsHeadAlone, hasStaged { parts.append("Vorgemerktes bleibt draußen (--only)") }
        if plan.autostash { parts.append("lokale Änderungen werden geparkt (--autostash)") }
        return RefString.joined(parts, separator: " · ")
    }

    private func save() {
        guard let editor, let commit, let plan, editor.saveButton.isEnabled else { return }
        let message = editor.message
        let command = plan.rewordsHeadAlone ? "git commit --amend --only" : "git rebase -i (reword \(commit.shortID))"
        let note = CommitActionsController.note(command, hint)
        editor.isSaving = true
        let repository = viewModel.repository
        Task {
            do {
                switch try await repository.reword(plan, message: message) {
                case let .rewritten(sha):
                    onRewritten?(commit.id, sha)
                    await viewModel.refresh(note: note)
                case let .stopped(progress, output):
                    await viewModel.refresh(note: note)
                    // A conflict is a state the banner shows; only a failed command is worth a message.
                    if case let .exec(command)? = progress.stop {
                        prompter.report(GitError(arguments: ["rebase"], exitCode: 1, stderr: output), title: "„\(command)“ fehlgeschlagen, Rebase angehalten")
                    }
                }
                finish()
            } catch {
                // Nothing was rewritten: the editor stays with the text for another try.
                editor.isSaving = false
                await viewModel.refresh(note: nil)
                let planError = error as? RebasePlanError
                prompter.report(planError.map { GitError(arguments: [], exitCode: 0, stderr: InteractiveRebaseController.describe($0)) } ?? error, title: "Nachricht nicht geändert")
            }
        }
    }

    private func finish() {
        editor = nil
        commit = nil
        plan = nil
        onClosed?()
    }
}
