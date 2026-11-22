import AppKit
import GitEngine

/// The context menu of a commit in the history beyond checking out, and running its actions with the questions they raise.
/// Checkouts stay with `CheckoutController`; their entries lead the menu.
@MainActor
final class CommitActionsController {
    let prompter = ActionPrompter()
    let interactiveRebase: InteractiveRebaseController
    private lazy var rebaseOnto = RebaseOntoController(viewModel: viewModel, interactive: interactiveRebase) { [weak self] note, operation in
        self?.runOperation(failure: "Rebase failed", conflict: "Rebase stopped on conflicts", note: note, endsRebase: true, operation)
    }
    private let viewModel: GraphViewModel
    /// Says what a rebase or cherry-pick left out, in a toast.
    var onToast: ((RefString) -> Void)?
    /// A rebase started here finished without stopping; the tab selects HEAD and leaves any open diff.
    var onRebaseEnded: (() -> Void)? {
        didSet { interactiveRebase.onEnded = onRebaseEnded }
    }

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
        interactiveRebase = InteractiveRebaseController(viewModel: viewModel, prompter: prompter)
    }

    /// The whole menu of a row: `checkoutItems` as the first group, the commit's actions in groups after them. Stashes and the working directory get only the checkout items.
    func menuItems(forRow index: Int, leadingWith checkoutItems: [NSMenuItem]) -> [NSMenuItem] {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .commit || viewModel.kinds[index] == .merge else { return checkoutItems }
        let commit = viewModel.commits[index]
        let groups = [checkoutItems, createItems(commit), historyItems(commit), interactiveRebase.menuItems(for: commit), copyItems(commit), tagItems(commit)].filter { !$0.isEmpty }
        return groups.enumerated().flatMap { offset, group in (offset > 0 ? [NSMenuItem.separator()] : []) + group }
    }

    // MARK: Menu

    private func createItems(_ commit: Commit) -> [NSMenuItem] {
        [
            ActionMenuItem("Create Worktree…") { [weak self] in self?.createWorktree(from: commit) },
            ActionMenuItem("Create Branch…") { [weak self] in self?.createBranch(at: commit) },
        ]
    }

    /// Entries that move the current branch are left out in detached HEAD, and where git would have nothing to do.
    private func historyItems(_ commit: Commit) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        guard let branch = viewModel.currentBranch else { return items }
        let isHead = commit.id == viewModel.headSHA
        let inBranch = viewModel.isReachableFromHead(commit.id)
        if !inBranch {
            items.append(ActionMenuItem("Cherry-pick onto \(RefName.branch(branch))") { [weak self] in self?.cherryPick(commit) })
        }
        items += rebaseOnto.items(branch: branch, commit: commit)
        if !isHead {
            let reset = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            reset.setTitle("Reset \(RefName.branch(branch)) to Here")
            let submenu = NSMenu()
            let modes: [(ResetMode, LocalizedStringResource)] = [(.soft, "Soft – Keep Changes Staged"), (.mixed, "Mixed – Keep Changes in Working Directory"), (.hard, "Hard – Discard Changes…")]
            for (mode, title) in modes {
                submenu.addItem(ActionMenuItem(title) { [weak self] in self?.reset(branch, to: commit, mode: mode) })
            }
            reset.submenu = submenu
            items.append(reset)
        }
        if inBranch {
            items.append(ActionMenuItem("Create Revert Commit") { [weak self] in self?.revert(commit) })
        }
        return items
    }

    private func copyItems(_ commit: Commit) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ActionMenuItem("Copy SHA") { Self.copy(commit.id) }]
        // A merge has no patch of its own; format-patch writes nothing for it.
        if commit.parents.count <= 1 {
            items.append(ActionMenuItem("Save Patch…") { [weak self] in self?.savePatch(commit) })
        }
        return items
    }

    private func tagItems(_ commit: Commit) -> [NSMenuItem] {
        [
            ActionMenuItem("Create Tag…") { [weak self] in self?.createTag(at: commit, annotated: false) },
            ActionMenuItem("Create Annotated Tag…") { [weak self] in self?.createTag(at: commit, annotated: true) },
        ]
    }

    // MARK: Actions

    private func createWorktree(from commit: Commit) {
        let form = ActionForm(title: "Create Worktree from \(RefName.commit(commit.id))", info: "The worktree gets its own folder. Without a branch name it stays on the commit (detached HEAD).", confirm: "Create")
        form.addFolderField(key: "path", label: "Folder", value: defaultWorktreePath(for: commit))
        form.addField(key: "branch", label: "New branch (optional)", required: false)
        Task {
            guard let values = await prompter.ask(form), let folder = values.value("path") else { return }
            let path = (folder as NSString).expandingTildeInPath
            let branch = values.value("branch")
            run(failure: "Worktree not created", note: "git worktree add") { try await $0.addWorktree(at: path, commit: commit.id, newBranch: branch) }
        }
    }

    private func createBranch(at commit: Commit) {
        let form = ActionForm(title: "Create Branch at \(RefName.commit(commit.id))", info: .verbatim(commit.subject), confirm: "Create")
        form.addField(key: "name", label: "Name", placeholder: "feature/…")
        form.addCheckbox("Check out branch", checked: true)
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            let checkout = values.isChecked
            run(failure: "Branch not created", note: checkout ? "git switch -c" : "git branch") { try await $0.createBranch(name, at: commit.id, checkout: checkout) }
        }
    }

    private func cherryPick(_ commit: Commit) {
        run(failure: "Cherry-pick failed", conflict: "Cherry-pick stopped on conflicts", note: "git cherry-pick") { try await $0.cherryPick(commit) }
    }

    private func revert(_ commit: Commit) {
        run(failure: "Revert failed", conflict: "Revert stopped on conflicts", note: "git revert") { try await $0.revert(commit) }
    }

    private func reset(_ branch: String, to commit: Commit, mode: ResetMode) {
        Task {
            let hint = await publishedHint(rewrittenBy: commit.id)
            // Only a hard reset asks: it throws away uncommitted work. Published commits only get the hint.
            if mode == .hard {
                let alert = NSAlert()
                let loss = RefString("Uncommitted changes to tracked files will be lost.")
                // The hint is a sentence of its own and goes into a paragraph of its own.
                let info = hint.map { RefString(marked: loss.marked + "\n\n" + $0.marked) } ?? loss
                alert.setText(RefString("Reset \(RefName.branch(branch)) to \(RefName.commit(commit.id)) (\(mode.rawValue))?"), info: info)
                alert.addButton(withTitle: String(localized: "Reset", bundle: .module, comment: "Button that resets a branch."))
                alert.addButton(withTitle: String(localized: "Cancel", bundle: .module))
                alert.buttons.first?.hasDestructiveAction = true
                guard await prompter.confirm(alert) else { return }
            }
            run(failure: "Reset failed", note: Self.note("git reset --\(mode.rawValue)", hint)) { try await $0.resetCurrentBranch(to: commit.id, mode: mode) }
        }
    }

    private func savePatch(_ commit: Commit) {
        let repository = viewModel.repository
        Task {
            guard let url = await prompter.saveLocation(title: "Save Commit as Patch", suggestedName: Self.patchName(for: commit)) else { return }
            do {
                try await repository.patch(of: commit.id).write(to: url)
            } catch {
                prompter.report(error, title: "Patch not saved")
            }
        }
    }

    private func createTag(at commit: Commit, annotated: Bool) {
        let title: LocalizedStringResource = annotated ? "Create Annotated Tag at \(RefName.commit(commit.id))" : "Create Tag at \(RefName.commit(commit.id))"
        let form = ActionForm(title: title, info: .verbatim(commit.subject), confirm: "Create")
        form.addField(key: "name", label: "Name", placeholder: "v1.0")
        if annotated { form.addMessage(label: "Message") }
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            let message = annotated ? values.text[ActionForm.messageKey] : nil
            run(failure: "Tag not created", note: annotated ? "git tag -a" : "git tag") { try await $0.createTag(name, at: commit.id, message: message) }
        }
    }

    // MARK: Running

    /// Runs one git write and refreshes the tab, also after a failure: a stopped cherry-pick, revert or rebase has changed the repository.
    private func run(failure: LocalizedStringResource, conflict: LocalizedStringResource? = nil, note: String, _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        runOperation(failure: failure, conflict: conflict, note: note, endsRebase: false) { repository in
            try await operation(repository)
            return nil
        }
    }

    /// Runs a rebase, cherry-pick or revert. Commits it left out as already applied show in a toast; a stop on conflicts is left to the banner, other failures are reported.
    /// A rebase that finished at once ends like one finished through the banner.
    private func runOperation(failure: LocalizedStringResource, conflict: LocalizedStringResource?, note: String, endsRebase: Bool, _ operation: @escaping @Sendable (Repository) async throws -> OperationReport?) {
        let repository = viewModel.repository
        Task {
            do {
                let report = try await operation(repository)
                await viewModel.refresh(note: note)
                if let toast = GitFailureText.toast(for: report) { onToast?(toast) }
                if endsRebase { onRebaseEnded?() }
            } catch {
                let report = (error as? GitError).map { OperationReport(output: $0.stderr) }
                await viewModel.refresh(note: nil)
                if let toast = GitFailureText.toast(for: report) { onToast?(toast) }
                let stopped = (error as? GitError)?.stoppedOnConflict == true
                let retry = GitFailureText.isBlockedByLocalChanges(error) ? [stashAndRetry(failure: failure, conflict: conflict, note: note, endsRebase: endsRebase, operation)] : []
                await prompter.report(error, title: stopped ? (conflict ?? failure) : failure, actions: retry, unlessStoppedIn: repository)
            }
        }
    }

    /// Runs the operation again with the local changes set aside and brought back afterwards; see `Repository.withLocalChangesStashed`.
    private func stashAndRetry(failure: LocalizedStringResource, conflict: LocalizedStringResource?, note: String, endsRebase: Bool, _ operation: @escaping @Sendable (Repository) async throws -> OperationReport?) -> FailureAction {
        let message = String(localized: "GitBonsai: before \(note)", bundle: .module, comment: "Message of the stash that carries local changes past a command; the argument is the git command.")
        let prompter = prompter
        let carried = String(localized: "\(note) · local changes carried along in a stash", bundle: .module, comment: "Status line after a command ran with the local changes stashed around it; the argument is the git command.")
        return FailureAction(title: "Stash Changes and Try Again") { [weak self] in
            self?.runOperation(failure: failure, conflict: conflict, note: carried, endsRebase: endsRebase) { repository in
                var report: OperationReport?
                let conflicted = try await repository.withLocalChangesStashed(message: message) { report = try await operation(repository) }
                if conflicted { await prompter.reportConflictingReturn(of: message) }
                return report
            }
        }
    }

    /// "3 commits are already on origin/feature; push afterwards only with --force-with-lease", or nil when nothing rewritten from `commit` on is published.
    func publishedHint(rewrittenBy commit: String) async -> RefString? {
        Self.publishedHint(await viewModel.repository.publishedCommitCount(rewrittenBy: commit), upstream: viewModel.status?.branch.upstream)
    }

    static func publishedHint(_ count: Int, upstream: String?) -> RefString? {
        guard count > 0 else { return nil }
        guard let upstream else { return RefString("\(count) commits are already on the upstream; push afterwards only with --force-with-lease") }
        return RefString("\(count) commits are already on \(RefName.remoteBranch(upstream)); push afterwards only with --force-with-lease")
    }

    /// The status line's note: the command, and the hint when there is one.
    static func note(_ command: String, _ hint: RefString?) -> String {
        ([command] + [hint?.plain].compactMap { $0 }).joined(separator: " · ")
    }

    /// Next to the main worktree, named after the repository and the commit.
    private func defaultWorktreePath(for commit: Commit) -> String {
        let main = viewModel.worktrees.first { $0.worktree.isMain }?.worktree.path ?? viewModel.repository.path
        let parent = (main as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent("\(viewModel.repositoryName)-\(commit.id.prefix(7))")
    }

    private static func patchName(for commit: Commit) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = commit.subject.lowercased().unicodeScalars.split { !allowed.contains($0) }.map { String(String.UnicodeScalarView($0)) }
        let slug = words.joined(separator: "-").prefix(52)
        return slug.isEmpty ? "\(commit.id.prefix(7)).patch" : "\(commit.id.prefix(7))-\(slug).patch"
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A menu item that runs a closure.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: LocalizedStringResource, handler: @escaping () -> Void) {
        self.handler = handler
        let title = RefString(title)
        super.init(title: title.plain, action: #selector(fire), keyEquivalent: "")
        target = self
        setTitle(title)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
