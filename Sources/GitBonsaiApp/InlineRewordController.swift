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
    /// An editor the panel dropped on navigation leaves its state behind; a new one starts without it.
    func begin(_ commit: Commit) {
        guard !isEditing, let detail, access(commit) == .allowed else { return NSSound.beep() }
        resetState()
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
            editor.showNote(RefString(verbatim: reason))
        }
    }

    /// "Rewrites 3 commits · 3 already on origin/develop", with what happens to uncommitted changes and branches that move along.
    static func note(_ plan: RebasePlan, published: Int, upstream: String?, hasStaged: Bool) -> RefString {
        var parts: [LocalizedStringResource] = [LocalizedStringResource("commit.reword.rewrites", defaultValue: "Rewrites \(plan.steps.count) commits", bundle: .module)]
        if published > 0 {
            parts.append(upstream.map { LocalizedStringResource("commit.reword.alreadyOnRemote", defaultValue: "\(published) already on \(RefName.remoteBranch($0))", bundle: .module) } ?? LocalizedStringResource("commit.reword.alreadyOnUpstream", defaultValue: "\(published) already on the upstream", bundle: .module))
        }
        let moving = plan.branches.values.flatMap { $0 }.map { $0.replacingOccurrences(of: "refs/heads/", with: "") }.sorted()
        if !moving.isEmpty { parts.append(LocalizedStringResource("commit.reword.alsoMoves", defaultValue: "also moves \(moving.map(RefName.branch).joined(separator: ", "))", bundle: .module)) }
        if plan.rewordsHeadAlone, hasStaged { parts.append(LocalizedStringResource("commit.reword.stagedStayOut", defaultValue: "staged changes stay out (--only)", bundle: .module)) }
        if plan.autostash { parts.append(LocalizedStringResource("commit.reword.autostash", defaultValue: "local changes are set aside (--autostash)", bundle: .module)) }
        return RefString(marked: parts.map(\.marked).joined(separator: " · "))
    }

    private func save() {
        guard let editor, let commit, let plan, editor.saveButton.isEnabled else { return }
        let message = editor.message
        let command = plan.rewordsHeadAlone ? "git commit --amend --only" : "git rebase -i (reword \(commit.shortID))"
        let note = CommitActionsController.note(command, hint)
        editor.isSaving = true
        let repository = viewModel.repository
        Task { [weak self] in
            guard let self else { return }
            do {
                switch try await repository.reword(plan, message: message) {
                case let .rewritten(sha):
                    onRewritten?(commit.id, sha)
                    await viewModel.refresh(note: note)
                case let .stopped(progress, output):
                    await viewModel.refresh(note: note)
                    // A conflict is a state the banner shows; only a failed command is worth a message.
                    if case let .exec(command)? = progress.stop {
                        prompter.report(GitError(arguments: ["rebase"], exitCode: 1, stderr: output), title: LocalizedStringResource("failure.rebase.execStopped", defaultValue: "“\(command)” failed, rebase stopped", bundle: .module))
                    }
                }
                finish(editor)
            } catch {
                // Nothing was rewritten: the editor stays with the text for another try.
                editor.isSaving = false
                await viewModel.refresh(note: nil)
                let planError = error as? RebasePlanError
                prompter.report(planError.map { GitError(arguments: [], exitCode: 0, stderr: InteractiveRebaseController.describe($0)) } ?? error, title: LocalizedStringResource("failure.reword.failed", defaultValue: "Couldn’t Change Message", bundle: .module))
            }
        }
    }

    /// A save that outlived its editor, because the user moved on and began editing another commit, leaves the newer editor's state alone.
    private func finish(_ saved: CommitMessageEditor) {
        guard saved === editor else { return }
        resetState()
        onClosed?()
    }

    private func resetState() {
        editor = nil
        commit = nil
        plan = nil
        hint = nil
    }
}
