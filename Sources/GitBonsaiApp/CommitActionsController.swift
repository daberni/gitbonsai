import AppKit
import GitEngine

/// The context menu of a commit in the history beyond checking out, and running its actions with the questions they raise.
/// Checkouts stay with `CheckoutController`; their entries lead the menu.
@MainActor
final class CommitActionsController {
    let prompter = ActionPrompter()
    private let viewModel: GraphViewModel

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
    }

    /// The whole menu of a row: `checkoutItems` first, the commit's actions in groups after them. Stashes and the working directory get only the checkout items.
    func menuItems(forRow index: Int, leadingWith checkoutItems: [NSMenuItem]) -> [NSMenuItem] {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .commit || viewModel.kinds[index] == .merge else { return checkoutItems }
        let commit = viewModel.commits[index]
        let groups = [checkoutItems + [worktreeItem(commit)], historyItems(commit), copyItems(commit), tagItems(commit)].filter { !$0.isEmpty }
        return groups.enumerated().flatMap { offset, group in (offset > 0 ? [NSMenuItem.separator()] : []) + group }
    }

    // MARK: Menu

    private func worktreeItem(_ commit: Commit) -> NSMenuItem {
        ActionMenuItem("Worktree aus diesem Commit anlegen …") { [weak self] in self?.createWorktree(from: commit) }
    }

    /// Entries that move or extend the current branch are left out in detached HEAD, and where git would have nothing to do.
    private func historyItems(_ commit: Commit) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ActionMenuItem("Branch hier anlegen …") { [weak self] in self?.createBranch(at: commit) }]
        guard let branch = viewModel.currentBranch else { return items }
        let isHead = commit.id == viewModel.headSHA
        let inBranch = viewModel.isReachableFromHead(commit.id)
        if !inBranch {
            items.append(ActionMenuItem("Cherry-pick auf „\(branch)“") { [weak self] in self?.cherryPick(commit) })
            items.append(ActionMenuItem("„\(branch)“ auf diesen Commit rebasen") { [weak self] in self?.rebase(branch, onto: commit) })
        }
        if !isHead {
            let reset = NSMenuItem(title: "„\(branch)“ hierher zurücksetzen", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (mode, title) in [(ResetMode.soft, "Soft – Änderungen bleiben vorgemerkt"), (.mixed, "Mixed – Änderungen bleiben im Arbeitsverzeichnis"), (.hard, "Hard – Änderungen verwerfen …")] {
                submenu.addItem(ActionMenuItem(title) { [weak self] in self?.reset(branch, to: commit, mode: mode) })
            }
            reset.submenu = submenu
            items.append(reset)
        }
        if inBranch && !isHead {
            items.append(ActionMenuItem("Ab hier auf … verschieben") { [weak self] in self?.rebaseOnto(branch, from: commit) })
        }
        if inBranch {
            items.append(ActionMenuItem("Commit reverten") { [weak self] in self?.revert(commit) })
        }
        return items
    }

    private func copyItems(_ commit: Commit) -> [NSMenuItem] {
        var items: [NSMenuItem] = [ActionMenuItem("SHA kopieren") { Self.copy(commit.id) }]
        // A merge has no patch of its own; format-patch writes nothing for it.
        if commit.parents.count <= 1 {
            items.append(ActionMenuItem("Als Patch speichern …") { [weak self] in self?.savePatch(commit) })
        }
        return items
    }

    private func tagItems(_ commit: Commit) -> [NSMenuItem] {
        [
            ActionMenuItem("Tag hier anlegen …") { [weak self] in self?.createTag(at: commit, annotated: false) },
            ActionMenuItem("Annotierten Tag hier anlegen …") { [weak self] in self?.createTag(at: commit, annotated: true) },
        ]
    }

    // MARK: Actions

    private func createWorktree(from commit: Commit) {
        let form = ActionForm(title: "Worktree aus \(commit.id.prefix(7)) anlegen", info: "Der Worktree bekommt einen eigenen Ordner. Ohne Branch-Namen steht er auf dem Commit (Detached HEAD).", confirm: "Anlegen")
        form.addFolderField(key: "path", label: "Ordner", value: defaultWorktreePath(for: commit))
        form.addField(key: "branch", label: "Neuer Branch (optional)", required: false)
        Task {
            guard let values = await prompter.ask(form), let folder = values.value("path") else { return }
            let path = (folder as NSString).expandingTildeInPath
            let branch = values.value("branch")
            run(failure: "Worktree nicht angelegt", note: "git worktree add") { try await $0.addWorktree(at: path, commit: commit.id, newBranch: branch) }
        }
    }

    private func createBranch(at commit: Commit) {
        let form = ActionForm(title: "Branch bei \(commit.id.prefix(7)) anlegen", info: commit.subject, confirm: "Anlegen")
        form.addField(key: "name", label: "Name", placeholder: "feature/…")
        form.addCheckbox("Branch auschecken", checked: true)
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            let checkout = values.isChecked
            run(failure: "Branch nicht angelegt", note: checkout ? "git switch -c" : "git branch") { try await $0.createBranch(name, at: commit.id, checkout: checkout) }
        }
    }

    private func cherryPick(_ commit: Commit) {
        run(failure: "Cherry-pick fehlgeschlagen", conflict: "Cherry-pick mit Konflikten angehalten", note: "git cherry-pick") { try await $0.cherryPick(commit) }
    }

    private func revert(_ commit: Commit) {
        run(failure: "Revert fehlgeschlagen", conflict: "Revert mit Konflikten angehalten", note: "git revert") { try await $0.revert(commit) }
    }

    private func rebase(_ branch: String, onto commit: Commit) {
        Task {
            let published = await viewModel.repository.publishedCommitCount(rewrittenBy: commit.id)
            if published > 0 {
                let alert = NSAlert()
                alert.messageText = "„\(branch)“ auf \(commit.id.prefix(7)) rebasen?"
                alert.informativeText = publishedWarning(published, branch: branch)
                alert.addButton(withTitle: "Rebasen")
                alert.addButton(withTitle: "Abbrechen")
                guard await prompter.confirm(alert) else { return }
            }
            run(failure: "Rebase fehlgeschlagen", conflict: "Rebase mit Konflikten angehalten", note: "git rebase") { try await $0.rebaseCurrentBranch(onto: commit.id) }
        }
    }

    /// Moves the commits of the current branch after `oldBase` onto a base the sheet asks for.
    private func rebaseOnto(_ branch: String, from oldBase: Commit) {
        let repository = viewModel.repository
        let candidates = viewModel.refs.filter { ref in
            switch ref.kind {
            case .localBranch: ref.name != branch
            case .remoteBranch: !ref.name.hasSuffix("/HEAD")
            case .tag: true
            default: false
            }
        }.map(\.name)
        let suggestion = ["main", "master", "origin/main", "origin/master"].first { candidates.contains($0) }
        Task {
            let moving = (try? await repository.commitCount(from: oldBase.id, to: branch)) ?? 0
            let published = await repository.publishedCommitCount(rewrittenBy: oldBase.id)
            let sheet = RebaseOntoSheet(branch: branch, oldBase: oldBase, moving: moving, candidates: candidates, suggestion: suggestion, warning: published > 0 ? publishedWarning(published, branch: branch) : nil, repository: repository)
            guard let newBase = await sheet.ask(using: prompter) else { return }
            run(failure: "Rebase fehlgeschlagen", conflict: "Rebase mit Konflikten angehalten", note: "git rebase --onto \(newBase)") { try await $0.rebase(onto: newBase, from: oldBase.id, branch: branch) }
        }
    }

    private func reset(_ branch: String, to commit: Commit, mode: ResetMode) {
        Task {
            let published = await viewModel.repository.publishedCommitCount(rewrittenBy: commit.id)
            if mode == .hard || published > 0 {
                let alert = NSAlert()
                alert.messageText = "„\(branch)“ auf \(commit.id.prefix(7)) zurücksetzen (\(mode.rawValue))?"
                var warnings: [String] = []
                if mode == .hard { warnings.append("Nicht committete Änderungen an versionierten Dateien gehen verloren.") }
                if published > 0 { warnings.append(publishedWarning(published, branch: branch)) }
                alert.informativeText = warnings.joined(separator: "\n\n")
                alert.addButton(withTitle: "Zurücksetzen")
                alert.addButton(withTitle: "Abbrechen")
                alert.buttons.first?.hasDestructiveAction = mode == .hard
                guard await prompter.confirm(alert) else { return }
            }
            run(failure: "Zurücksetzen fehlgeschlagen", note: "git reset --\(mode.rawValue)") { try await $0.resetCurrentBranch(to: commit.id, mode: mode) }
        }
    }

    private func savePatch(_ commit: Commit) {
        let repository = viewModel.repository
        Task {
            guard let url = await prompter.saveLocation(title: "Commit als Patch speichern", suggestedName: Self.patchName(for: commit)) else { return }
            do {
                try await repository.patch(of: commit.id).write(to: url)
            } catch {
                prompter.report(error, title: "Patch nicht gespeichert")
            }
        }
    }

    private func createTag(at commit: Commit, annotated: Bool) {
        let title = annotated ? "Annotierten Tag bei \(commit.id.prefix(7)) anlegen" : "Tag bei \(commit.id.prefix(7)) anlegen"
        let form = ActionForm(title: title, info: commit.subject, confirm: "Anlegen")
        form.addField(key: "name", label: "Name", placeholder: "v1.0")
        if annotated { form.addMessage(label: "Nachricht") }
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            let message = annotated ? values.text[ActionForm.messageKey] : nil
            run(failure: "Tag nicht angelegt", note: annotated ? "git tag -a" : "git tag") { try await $0.createTag(name, at: commit.id, message: message) }
        }
    }

    // MARK: Running

    /// Runs one git write and refreshes the tab, also after a failure: a stopped cherry-pick, revert or rebase has changed the repository.
    private func run(failure: String, conflict: String? = nil, note: String, _ operation: @escaping @Sendable (Repository) async throws -> Void) {
        let repository = viewModel.repository
        Task {
            do {
                try await operation(repository)
                await viewModel.refresh(note: note)
            } catch {
                await viewModel.refresh(note: nil)
                let stopped = (error as? GitError)?.stoppedOnConflict == true
                prompter.report(error, title: stopped ? (conflict ?? failure) : failure)
            }
        }
    }

    private func publishedWarning(_ count: Int, branch: String) -> String {
        let upstream = viewModel.status?.branch.upstream ?? "dem Upstream"
        let commits = count == 1 ? "Ein Commit, der dabei neu geschrieben wird, ist" : "\(count) Commits, die dabei neu geschrieben werden, sind"
        return "\(commits) schon in „\(upstream)“. Danach lässt sich „\(branch)“ nur noch mit Force-Push hochladen."
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
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
