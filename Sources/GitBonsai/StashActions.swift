import AppKit
import GitEngine

/// The Stashes popover of the sidebar and the toolbar's Stash and Pop: making a stash, taking it back, and showing, applying, popping, dropping or branching one.
@MainActor
final class StashActions {
    /// Selects a commit in the history.
    var onNavigate: ((String) -> Void)?
    /// Shows a stash's changes: the stash selected in the history with the diff of its first file.
    var onShowDiff: ((Stash) -> Void)?
    private let prompter: any Prompting
    let popover: PanelPopover
    private let viewModel: GraphViewModel
    private let runner: ActionRunner

    init(context: RepositoryContext) {
        viewModel = context.model
        prompter = context.prompter
        runner = context.runner
        popover = PanelPopover(list: PanelListView(title: LocalizedStringResource("stash.panel.title", defaultValue: "Stashes", bundle: .module), empty: LocalizedStringResource("stash.panel.empty", defaultValue: "No stashes", bundle: .module), noMatch: LocalizedStringResource("stash.panel.noMatch", defaultValue: "No matching stashes", bundle: .module), filterPlaceholder: LocalizedStringResource("stash.panel.filter", defaultValue: "Filter stashes", bundle: .module)))
        let list = popover.list
        list.onSelect = { [weak self] id in self?.onNavigate?(id) }
        list.onActivate = { [weak self] id in self?.showDiff(id) }
        list.actions = [
            PanelAction(LocalizedStringResource("stash.action.showDiff", defaultValue: "Show Diff", bundle: .module)) { [weak self] id in self?.showDiff(id) },
            PanelAction(LocalizedStringResource("stash.action.apply", defaultValue: "Apply Stash", bundle: .module)) { [weak self] id in self?.apply(id) },
            PanelAction(LocalizedStringResource("stash.action.pop", defaultValue: "Pop Stash", bundle: .module)) { [weak self] id in self?.pop(id) },
            PanelAction(LocalizedStringResource("commit.menu.createBranch", defaultValue: "Create Branch…", bundle: .module)) { [weak self] id in self?.createBranch(id) },
            PanelAction(LocalizedStringResource("stash.action.drop", defaultValue: "Drop Stash…", bundle: .module), isDestructive: true) { [weak self] id in self?.drop(id) },
        ]
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        reload()
        popover.show(relativeTo: rect, of: view)
    }

    /// Called whenever the tab refreshed; an open list follows the stash list.
    func viewModelChanged() {
        guard popover.isShown else { return }
        reload()
    }

    private func reload() {
        popover.list.show(viewModel.stashes.map(Self.row))
        popover.fitContent()
    }

    private static func row(_ stash: Stash) -> PanelRow {
        let detail = [stash.selector, stash.branch ?? String(localized: "common.detachedHead", defaultValue: "Detached HEAD", bundle: .module)].joined(separator: " · ")
        return PanelRow(id: stash.commitID, glyph: .stashBowl, title: stash.text, marker: nil, tooltip: nil, detail: detail, date: stash.date, sha: String(stash.commitID.prefix(RefString.shortSHA)), searchText: stash.message)
    }

    private func stash(_ id: String) -> Stash? { viewModel.stashes.first { $0.commitID == id } }

    // MARK: Menu

    /// A stash's menu in the shared group order: go there (show) | integrate (apply, pop) | remove (drop) | create (branch).
    func groups(for id: String) -> (show: [MenuEntry], takeBack: [MenuEntry], drop: [MenuEntry], create: [MenuEntry]) {
        let show = [MenuEntry(LocalizedStringResource("stash.action.showDiff", defaultValue: "Show Diff", bundle: .module)) { [weak self] in self?.showDiff(id) }]
        let takeBack = [
            MenuEntry(LocalizedStringResource("stash.action.apply", defaultValue: "Apply Stash", bundle: .module)) { [weak self] in self?.apply(id) }.movingHead,
            MenuEntry(LocalizedStringResource("stash.action.pop", defaultValue: "Pop Stash", bundle: .module)) { [weak self] in self?.pop(id) }.movingHead,
        ]
        let create = [MenuEntry(LocalizedStringResource("commit.menu.createBranch", defaultValue: "Create Branch…", bundle: .module)) { [weak self] in self?.createBranch(id) }]
        let drop = [MenuEntry(LocalizedStringResource("stash.action.drop", defaultValue: "Drop Stash…", bundle: .module)) { [weak self] in self?.drop(id) }]
        return (show, takeBack, drop, create)
    }

    // MARK: Toolbar

    /// The toolbar's Stash menu: stashing everything at once is its default; the others ask for a message or take only the staged changes.
    func toolbarGroups() -> [[MenuEntry]] {
        var all = MenuEntry(LocalizedStringResource("stash.menu.all", defaultValue: "Stash all changes", bundle: .module)) { [weak self] in self?.stashNow(.includingUntracked) }
        all.toolTip = String(localized: "stash.menu.allToolTip", defaultValue: "\(StashScope.includingUntracked.commandLine) -m “WIP on <branch>: <HEAD>”", bundle: .module, comment: "Tooltip: the git command with the message it writes; <branch> and <HEAD> are placeholders.")
        let message = MenuEntry(LocalizedStringResource("stash.action.withMessage", defaultValue: "Stash with Message…", bundle: .module)) { [weak self] in self?.stashWithMessage() }
        var staged = MenuEntry(LocalizedStringResource("stash.action.stagedOnly", defaultValue: "Stash staged changes only", bundle: .module)) { [weak self] in self?.stashNow(.staged) }
        staged.toolTip = StashScope.staged.commandLine
        staged.disabledReason = hasStagedChanges ? nil : CommandBlocker.nothingStaged.reason.text
        return [[all, message, staged]]
    }

    var hasStagedChanges: Bool { !(viewModel.status?.staged.isEmpty ?? true) }

    /// Stashes without asking, under git's default style of message in the app's words; a toast offers to take it back.
    func stashNow(_ scope: StashScope) {
        Task {
            let parts = await viewModel.repository.defaultStashMessageParts()
            await stash(message: Self.defaultMessage(branch: parts.branch, subject: parts.subject), scope: scope)
        }
    }

    /// "WIP on <branch>: <subject of HEAD>", written into the repository in the interface language.
    private static func defaultMessage(branch: String?, subject: String) -> String {
        let place = branch ?? String(localized: "common.detachedHead", defaultValue: "Detached HEAD", bundle: .module)
        if subject.isEmpty { return String(localized: "stash.message.wip", defaultValue: "WIP on \(place)", bundle: .module, comment: "Stash message; the branch, or Detached HEAD.") }
        return String(localized: "stash.message.wipSubject", defaultValue: "WIP on \(place): \(subject)", bundle: .module, comment: "Stash message: the branch, or Detached HEAD, then the subject of HEAD.")
    }

    /// Asks for a message and whether untracked files go along, then stashes.
    func stashWithMessage() {
        let form = ActionForm(title: LocalizedStringResource("stash.action.stashChanges", defaultValue: "Stash changes", bundle: .module), confirm: LocalizedStringResource("stash.form.confirm", defaultValue: "Stash", bundle: .module, comment: "Button that stashes the changes."))
        form.addField(key: "message", label: LocalizedStringResource("stash.form.message", defaultValue: "Message (optional)", bundle: .module), placeholder: String(localized: "stash.form.messagePlaceholder", defaultValue: "WIP", bundle: .module, comment: "Placeholder of a stash message: work in progress."), required: false)
        form.addCheckbox(LocalizedStringResource("stash.form.includeUntracked", defaultValue: "Include untracked files", bundle: .module), checked: true)
        Task {
            guard let values = await prompter.ask(form) else { return }
            let message = values.value("message")
            await stash(message: message, scope: values.isChecked ? .includingUntracked : .tracked)
        }
    }

    private func stash(message: String?, scope: StashScope) async {
        let repository = viewModel.repository
        do {
            let created = try await repository.stash(message: message, scope: scope)
            await viewModel.refresh(note: created == nil ? nil : scope.commandLine)
            guard let created else {
                prompter.toast(RefString(LocalizedStringResource("stash.toast.nothingToStash", defaultValue: "Nothing to stash", bundle: .module)))
                return
            }
            prompter.toast(RefString(LocalizedStringResource("stash.toast.stashed", defaultValue: "Stashed: \(RefName.stash(created.stash.text))", bundle: .module)), action: ToastAction(title: LocalizedStringResource("stash.toast.undo", defaultValue: "Undo Stash", bundle: .module)) { [weak self] in self?.undo(created) })
        } catch {
            await viewModel.refresh(note: nil)
            prompter.report(error, title: LocalizedStringResource("failure.stash.notCreated", defaultValue: "Stash not created", bundle: .module))
        }
    }

    /// Pops the stash just made back, as long as nothing changed since; otherwise a toast says why it stays.
    private func undo(_ created: NewStash) {
        let repository = viewModel.repository
        Task {
            do {
                try await repository.undoStash(created)
                await viewModel.refresh(note: "git stash pop --index stash@{0}")
                prompter.toast(RefString(LocalizedStringResource("stash.toast.undone", defaultValue: "Stash taken back: \(RefName.stash(created.stash.text))", bundle: .module)))
            } catch let error as StashUndoError {
                prompter.toast(RefString(Self.notUndone(error)))
            } catch {
                await viewModel.refresh(note: nil)
                prompter.report(error, title: LocalizedStringResource("failure.stash.notUndone", defaultValue: "Stash not taken back", bundle: .module))
            }
        }
    }

    private static func notUndone(_ error: StashUndoError) -> LocalizedStringResource {
        switch error {
        case .notNewest: LocalizedStringResource("stash.undo.notNewest", defaultValue: "Not undone: there is a newer stash by now; the stash stays in the list", bundle: .module)
        case .headMoved: LocalizedStringResource("stash.undo.headMoved", defaultValue: "Not undone: HEAD has moved since; the stash stays in the list", bundle: .module)
        case .workingTreeChanged: LocalizedStringResource("stash.undo.workingTreeChanged", defaultValue: "Not undone: the working directory has changed since; the stash stays in the list", bundle: .module)
        }
    }

    /// Pops the newest stash. A conflict is reported with git's message and left as git left it.
    func popNewest() {
        guard let newest = viewModel.stashes.first else { return }
        pop(newest.commitID)
    }

    // MARK: Actions

    private func showDiff(_ id: String) {
        guard let stash = stash(id) else { return }
        popover.close()
        onShowDiff?(stash)
    }

    func apply(_ id: String) {
        guard let stash = stash(id) else { return }
        runner.run(failure: LocalizedStringResource("failure.stash.notApplied", defaultValue: "Stash not applied", bundle: .module), conflict: LocalizedStringResource("failure.stash.appliedWithConflicts", defaultValue: "Stash applied with conflicts", bundle: .module), note: "git stash apply \(stash.selector)", focus: .current) { try await $0.applyStash(stash) }
    }

    func pop(_ id: String) {
        guard let stash = stash(id) else { return }
        runner.run(failure: LocalizedStringResource("failure.stash.notApplied", defaultValue: "Stash not applied", bundle: .module), conflict: LocalizedStringResource("failure.stash.poppedWithConflicts", defaultValue: "Stash applied with conflicts; it stays", bundle: .module), note: "git stash pop \(stash.selector)", focus: .current) { try await $0.popStash(stash) }
    }

    func drop(_ id: String) {
        guard let stash = stash(id) else { return }
        Task {
            guard await runner.confirm(LocalizedStringResource("stash.drop.title", defaultValue: "Drop Stash?", bundle: .module), names: RefString(marked: RefName.stash(stash.selector) + " " + stash.text), button: LocalizedStringResource("stash.drop.confirm", defaultValue: "Drop", bundle: .module, comment: "Button that deletes a stash.")) else { return }
            runner.run(failure: LocalizedStringResource("failure.stash.notDeleted", defaultValue: "Stash not deleted", bundle: .module), note: "git stash drop \(stash.selector)") { try await $0.dropStash(stash) }
        }
    }

    func createBranch(_ id: String) {
        guard let stash = stash(id) else { return }
        let form = ActionForm(title: LocalizedStringResource("stash.createBranch.title", defaultValue: "Create Branch from \(RefName.stash(stash.selector))", bundle: .module), confirm: LocalizedStringResource("common.create", defaultValue: "Create", bundle: .module))
        form.addField(key: "name", label: LocalizedStringResource("common.name", defaultValue: "Name", bundle: .module, comment: "Label of a branch name field."), placeholder: "feature/…")
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            popover.close()
            runner.run(failure: LocalizedStringResource("failure.branch.notCreated", defaultValue: "Branch not created", bundle: .module), note: "git stash branch \(name)") { try await $0.createBranch(name, from: stash) }
        }
    }
}
