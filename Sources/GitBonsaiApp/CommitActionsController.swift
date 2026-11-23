import AppKit
import GitEngine

/// The context menu of a commit in the history beyond checking out, and running its actions with the questions they raise.
/// Checkouts stay with `CheckoutController`; their entries lead the menu.
@MainActor
final class CommitActionsController {
    let prompter = ActionPrompter()
    let interactiveRebase: InteractiveRebaseController
    private lazy var rebaseOnto = RebaseOntoController(viewModel: viewModel, interactive: interactiveRebase) { [weak self] note, operation in
        self?.runOperation(failure: LocalizedStringResource("failure.rebase.failed", defaultValue: "Rebase failed", bundle: .module), conflict: LocalizedStringResource("failure.rebase.conflicts", defaultValue: "Rebase stopped on conflicts", bundle: .module), note: note, endsRebase: true, operation)
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
            ActionMenuItem(LocalizedStringResource("commit.menu.createWorktree", defaultValue: "Create Worktree…", bundle: .module)) { [weak self] in self?.createWorktree(from: commit) },
            ActionMenuItem(LocalizedStringResource("commit.menu.createBranch", defaultValue: "Create Branch…", bundle: .module)) { [weak self] in self?.createBranch(at: commit) },
        ]
    }

    /// Entries that move the current branch are left out in detached HEAD, and where git would have nothing to do.
    private func historyItems(_ commit: Commit) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        guard let branch = viewModel.currentBranch else { return items }
        let isHead = commit.id == viewModel.headSHA
        let inBranch = viewModel.isReachableFromHead(commit.id)
        if !inBranch {
            items.append(ActionMenuItem(LocalizedStringResource("commit.menu.cherryPick", defaultValue: "Cherry-Pick onto \(RefName.branch(branch))", bundle: .module)) { [weak self] in self?.cherryPick(commit) })
        }
        items += rebaseOnto.items(branch: branch, commit: commit)
        if !isHead {
            let reset = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            reset.setTitle(LocalizedStringResource("commit.menu.reset", defaultValue: "Reset \(RefName.branch(branch)) to here", bundle: .module))
            let submenu = NSMenu()
            let modes: [(ResetMode, LocalizedStringResource)] = [(.soft, LocalizedStringResource("commit.menu.resetSoft", defaultValue: "Soft – keep changes staged", bundle: .module)), (.mixed, LocalizedStringResource("commit.menu.resetMixed", defaultValue: "Mixed – keep changes in working directory", bundle: .module)), (.hard, LocalizedStringResource("commit.menu.resetHard", defaultValue: "Hard – discard changes…", bundle: .module))]
            for (mode, title) in modes {
                submenu.addItem(ActionMenuItem(title) { [weak self] in self?.reset(branch, to: commit, mode: mode) })
            }
            reset.submenu = submenu
            items.append(reset)
        }
        if inBranch {
            items.append(ActionMenuItem(LocalizedStringResource("commit.menu.revert", defaultValue: "Revert Commit", bundle: .module)) { [weak self] in self?.revert(commit) })
        }
        return items
    }

    private func copyItems(_ commit: Commit) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ActionMenuItem(LocalizedStringResource("common.copySHA", defaultValue: "Copy SHA", bundle: .module)) { ActionRunner.copy(commit.id) }]
        // A merge has no patch of its own; format-patch writes nothing for it.
        if commit.parents.count <= 1 {
            items.append(ActionMenuItem(LocalizedStringResource("commit.menu.savePatch", defaultValue: "Save Patch…", bundle: .module)) { [weak self] in self?.savePatch(commit) })
        }
        return items
    }

    private func tagItems(_ commit: Commit) -> [NSMenuItem] {
        [
            ActionMenuItem(LocalizedStringResource("commit.menu.createTag", defaultValue: "Create Tag…", bundle: .module)) { [weak self] in self?.createTag(at: commit, annotated: false) },
            ActionMenuItem(LocalizedStringResource("commit.menu.createAnnotatedTag", defaultValue: "Create annotated Tag…", bundle: .module)) { [weak self] in self?.createTag(at: commit, annotated: true) },
        ]
    }

    // MARK: Actions

    private func createWorktree(from commit: Commit) {
        let form = ActionForm(title: LocalizedStringResource("commit.createWorktree.title", defaultValue: "Create Worktree from \(RefName.commit(commit.id))", bundle: .module), info: LocalizedStringResource("commit.createWorktree.info", defaultValue: "The worktree gets its own folder. Without a branch name it stays on the commit (detached HEAD).", bundle: .module), confirm: LocalizedStringResource("common.create", defaultValue: "Create", bundle: .module))
        form.addFolderField(key: "path", label: LocalizedStringResource("common.folder", defaultValue: "Folder", bundle: .module), value: defaultWorktreePath(for: commit))
        form.addField(key: "branch", label: LocalizedStringResource("commit.createWorktree.branch", defaultValue: "New branch (optional)", bundle: .module), required: false)
        Task {
            guard let values = await prompter.ask(form), let folder = values.value("path") else { return }
            let path = (folder as NSString).expandingTildeInPath
            let branch = values.value("branch")
            run(failure: LocalizedStringResource("failure.worktree.notCreated", defaultValue: "Worktree not created", bundle: .module), note: "git worktree add") { try await $0.addWorktree(at: path, commit: commit.id, newBranch: branch) }
        }
    }

    private func createBranch(at commit: Commit) {
        let form = ActionForm(title: LocalizedStringResource("commit.createBranch.title", defaultValue: "Create Branch at \(RefName.commit(commit.id))", bundle: .module), info: .verbatim(commit.subject), confirm: LocalizedStringResource("common.create", defaultValue: "Create", bundle: .module))
        form.addField(key: "name", label: LocalizedStringResource("common.name", defaultValue: "Name", bundle: .module), placeholder: "feature/…")
        form.addCheckbox(LocalizedStringResource("commit.createBranch.checkout", defaultValue: "Check out branch", bundle: .module), checked: true)
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            let checkout = values.isChecked
            run(failure: LocalizedStringResource("failure.branch.notCreated", defaultValue: "Branch not created", bundle: .module), note: checkout ? "git switch -c" : "git branch") { try await $0.createBranch(name, at: commit.id, checkout: checkout) }
        }
    }

    private func cherryPick(_ commit: Commit) {
        run(failure: LocalizedStringResource("failure.cherryPick.failed", defaultValue: "Cherry-pick failed", bundle: .module), conflict: LocalizedStringResource("failure.cherryPick.conflicts", defaultValue: "Cherry-pick stopped on conflicts", bundle: .module), note: "git cherry-pick") { try await $0.cherryPick(commit) }
    }

    private func revert(_ commit: Commit) {
        run(failure: LocalizedStringResource("failure.revert.failed", defaultValue: "Revert failed", bundle: .module), conflict: LocalizedStringResource("failure.revert.conflicts", defaultValue: "Revert stopped on conflicts", bundle: .module), note: "git revert") { try await $0.revert(commit) }
    }

    private func reset(_ branch: String, to commit: Commit, mode: ResetMode) {
        Task {
            let hint = await publishedHint(rewrittenBy: commit.id)
            // Only a hard reset asks: it throws away uncommitted work. Published commits only get the hint.
            if mode == .hard {
                let alert = NSAlert()
                let loss = RefString(LocalizedStringResource("commit.reset.loss", defaultValue: "Uncommitted changes to tracked files will be lost.", bundle: .module))
                // The hint is a sentence of its own and goes into a paragraph of its own.
                let info = hint.map { RefString(marked: loss.marked + "\n\n" + $0.marked) } ?? loss
                alert.setText(RefString(LocalizedStringResource("commit.reset.title", defaultValue: "Reset \(RefName.branch(branch)) to \(RefName.commit(commit.id)) (\(mode.rawValue))?", bundle: .module)), info: info)
                alert.addButton(withTitle: String(localized: "common.reset", defaultValue: "Reset", bundle: .module, comment: "Button that resets a branch."))
                alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module))
                alert.buttons.first?.hasDestructiveAction = true
                guard await prompter.confirm(alert) else { return }
            }
            run(failure: LocalizedStringResource("failure.reset.failed", defaultValue: "Reset failed", bundle: .module), note: Self.note("git reset --\(mode.rawValue)", hint)) { try await $0.resetCurrentBranch(to: commit.id, mode: mode) }
        }
    }

    private func savePatch(_ commit: Commit) {
        let repository = viewModel.repository
        Task {
            guard let url = await prompter.saveLocation(title: LocalizedStringResource("commit.savePatch.panelTitle", defaultValue: "Save Commit as Patch", bundle: .module), suggestedName: Self.patchName(for: commit)) else { return }
            do {
                try await repository.patch(of: commit.id).write(to: url)
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.patch.notSaved", defaultValue: "Patch not saved", bundle: .module))
            }
        }
    }

    private func createTag(at commit: Commit, annotated: Bool) {
        let title: LocalizedStringResource = annotated ? LocalizedStringResource("commit.createTag.annotatedTitle", defaultValue: "Create annotated Tag at \(RefName.commit(commit.id))", bundle: .module) : LocalizedStringResource("commit.createTag.title", defaultValue: "Create Tag at \(RefName.commit(commit.id))", bundle: .module)
        let form = ActionForm(title: title, info: .verbatim(commit.subject), confirm: LocalizedStringResource("common.create", defaultValue: "Create", bundle: .module))
        form.addField(key: "name", label: LocalizedStringResource("common.name", defaultValue: "Name", bundle: .module), placeholder: "v1.0")
        if annotated { form.addMessage(label: LocalizedStringResource("commit.createTag.message", defaultValue: "Message", bundle: .module)) }
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            let message = annotated ? values.text[ActionForm.messageKey] : nil
            run(failure: LocalizedStringResource("failure.tag.notCreated", defaultValue: "Tag not created", bundle: .module), note: annotated ? "git tag -a" : "git tag") { try await $0.createTag(name, at: commit.id, message: message) }
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
        let message = String(localized: "stash.message.before", defaultValue: "GitBonsai: before \(note)", bundle: .module, comment: "Message of the stash that carries local changes past a command; the argument is the git command.")
        let prompter = prompter
        let carried = String(localized: "stash.message.carriedAlong", defaultValue: "\(note) · local changes carried along in a stash", bundle: .module, comment: "Status line after a command ran with the local changes stashed around it; the argument is the git command.")
        return FailureAction(title: LocalizedStringResource("failure.action.stashAndRetry", defaultValue: "Stash changes and try again", bundle: .module)) { [weak self] in
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
        guard let upstream else { return RefString(LocalizedStringResource("commit.rewrite.alreadyOnUpstream", defaultValue: "\(count) commits are already on the upstream; push afterwards only with --force-with-lease", bundle: .module)) }
        return RefString(LocalizedStringResource("commit.rewrite.alreadyOnRemote", defaultValue: "\(count) commits are already on \(RefName.remoteBranch(upstream)); push afterwards only with --force-with-lease", bundle: .module))
    }

    /// The status line's note: the command, and the hint when there is one.
    static func note(_ command: String, _ hint: RefString?) -> String {
        ([command] + [hint?.plain].compactMap { $0 }).joined(separator: " · ")
    }

    /// Next to the main worktree, named after the repository and the commit.
    private func defaultWorktreePath(for commit: Commit) -> String {
        let main = viewModel.worktrees.first { $0.worktree.isMain }?.worktree.path ?? viewModel.repository.path
        let parent = (main as NSString).deletingLastPathComponent
        return (parent as NSString).appendingPathComponent("\(viewModel.repositoryName)-\(commit.id.prefix(RefString.shortSHA))")
    }

    private static func patchName(for commit: Commit) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = commit.subject.lowercased().unicodeScalars.split { !allowed.contains($0) }.map { String(String.UnicodeScalarView($0)) }
        let slug = words.joined(separator: "-").prefix(52)
        return slug.isEmpty ? "\(commit.id.prefix(RefString.shortSHA)).patch" : "\(commit.id.prefix(RefString.shortSHA))-\(slug).patch"
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
