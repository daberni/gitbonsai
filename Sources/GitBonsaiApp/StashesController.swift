import AppKit
import GitEngine

/// The Stashes popover of the sidebar and the toolbar's Stash and Pop: making a stash, taking it back, and showing, applying, popping, dropping or branching one.
@MainActor
final class StashesController {
    /// Selects a commit in the history.
    var onNavigate: ((String) -> Void)?
    /// Shows a stash's changes: the stash selected in the history with the diff of its first file.
    var onShowDiff: ((Stash) -> Void)?
    let prompter = ActionPrompter()
    let popover: PanelPopover
    private let viewModel: GraphViewModel
    private var runner: ActionRunner { ActionRunner(viewModel: viewModel, prompter: prompter) }

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
        popover = PanelPopover(list: PanelListView(title: "Stashes", empty: "No stashes", noMatch: "No matching stashes", filterPlaceholder: "Filter stashes"))
        let list = popover.list
        list.onSelect = { [weak self] id in self?.onNavigate?(id) }
        list.onActivate = { [weak self] id in self?.showDiff(id) }
        list.menuItems = { [weak self] id in self?.menuItems(for: id) ?? [] }
        list.actions = [
            PanelAction("Show Diff") { [weak self] id in self?.showDiff(id) },
            PanelAction("Apply Stash") { [weak self] id in self?.apply(id) },
            PanelAction("Pop") { [weak self] id in self?.pop(id) },
            PanelAction(LocalizedStringResource("Branch…", comment: "Creates a branch from a stash.")) { [weak self] id in self?.createBranch(id) },
            PanelAction("Drop…", isDestructive: true) { [weak self] id in self?.drop(id) },
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
        let detail = [stash.selector, stash.branch ?? String(localized: "Detached HEAD", bundle: .module)].joined(separator: " · ")
        return PanelRow(id: stash.commitID, glyph: .stashBowl, title: stash.text, marker: nil, tooltip: nil, detail: detail, date: stash.date, sha: String(stash.commitID.prefix(7)), searchText: stash.message)
    }

    private func stash(_ id: String) -> Stash? { viewModel.stashes.first { $0.commitID == id } }

    // MARK: Menu

    func menuItems(for id: String) -> [NSMenuItem] {
        [
            ActionMenuItem("Show Diff") { [weak self] in self?.showDiff(id) },
            .separator(),
            ActionMenuItem("Apply Stash") { [weak self] in self?.apply(id) },
            ActionMenuItem("Pop") { [weak self] in self?.pop(id) },
            ActionMenuItem("Create Branch from Stash…") { [weak self] in self?.createBranch(id) },
            .separator(),
            ActionMenuItem("Drop…") { [weak self] in self?.drop(id) },
        ]
    }

    // MARK: Toolbar

    /// The toolbar's Stash menu: stashing everything at once is its default; the others ask for a message or take only the staged changes.
    func stashMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all = ActionMenuItem("Stash All Changes") { [weak self] in self?.stashNow(.includingUntracked) }
        all.toolTip = String(localized: "\(StashScope.includingUntracked.commandLine) -m “WIP on <branch>: <HEAD>”", bundle: .module, comment: "Tooltip: the git command with the message it writes; <branch> and <HEAD> are placeholders.")
        menu.addItem(all)
        menu.addItem(ActionMenuItem("Stash with Message…") { [weak self] in self?.stashWithMessage() })
        let staged = ActionMenuItem("Stash Staged Changes Only") { [weak self] in self?.stashNow(.staged) }
        staged.toolTip = StashScope.staged.commandLine
        staged.isEnabled = hasStagedChanges
        menu.addItem(staged)
        return menu
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
        let place = branch ?? String(localized: "Detached HEAD", bundle: .module)
        if subject.isEmpty { return String(localized: "WIP on \(place)", bundle: .module, comment: "Stash message; the branch, or Detached HEAD.") }
        return String(localized: "WIP on \(place): \(subject)", bundle: .module, comment: "Stash message: the branch, or Detached HEAD, then the subject of HEAD.")
    }

    /// Asks for a message and whether untracked files go along, then stashes.
    func stashWithMessage() {
        let form = ActionForm(title: "Stash Changes", info: "All changes in the working directory go into a new stash.", confirm: LocalizedStringResource("Stash", comment: "Button that stashes the changes."))
        form.addField(key: "message", label: "Message (optional)", placeholder: String(localized: "WIP", bundle: .module, comment: "Placeholder of a stash message: work in progress."), required: false)
        form.addCheckbox("Include untracked files", checked: true)
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
                prompter.onToast?(RefString("Nothing to stash"), nil)
                return
            }
            prompter.onToast?(RefString("Stashed: \(RefName.stash(created.stash.text))"), ToastAction(title: "Undo Stash") { [weak self] in self?.undo(created) })
        } catch {
            await viewModel.refresh(note: nil)
            prompter.report(error, title: "Stash not created")
        }
    }

    /// Pops the stash just made back, as long as nothing changed since; otherwise a toast says why it stays.
    private func undo(_ created: NewStash) {
        let repository = viewModel.repository
        Task {
            do {
                try await repository.undoStash(created)
                await viewModel.refresh(note: "git stash pop --index stash@{0}")
                prompter.onToast?(RefString("Stash taken back: \(RefName.stash(created.stash.text))"), nil)
            } catch let error as StashUndoError {
                prompter.onToast?(RefString(Self.notUndone(error)), nil)
            } catch {
                await viewModel.refresh(note: nil)
                prompter.report(error, title: "Stash not taken back")
            }
        }
    }

    private static func notUndone(_ error: StashUndoError) -> LocalizedStringResource {
        switch error {
        case .notNewest: "Not undone: there is a newer stash by now; the stash stays in the list"
        case .headMoved: "Not undone: HEAD has moved since; the stash stays in the list"
        case .workingTreeChanged: "Not undone: the working directory has changed since; the stash stays in the list"
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
        runner.run(failure: "Stash not applied", conflict: "Stash applied with conflicts", note: "git stash apply \(stash.selector)") { try await $0.applyStash(stash) }
    }

    func pop(_ id: String) {
        guard let stash = stash(id) else { return }
        runner.run(failure: "Stash not applied", conflict: "Stash applied with conflicts; it stays", note: "git stash pop \(stash.selector)", focus: .head) { try await $0.popStash(stash) }
    }

    func drop(_ id: String) {
        guard let stash = stash(id) else { return }
        Task {
            guard await runner.confirm("Drop \(RefName.stash(stash.selector))?", info: "“\(stash.text)” is deleted. The changes in it are lost afterwards.", button: LocalizedStringResource("Drop", comment: "Button that deletes a stash.")) else { return }
            runner.run(failure: "Stash not deleted", note: "git stash drop \(stash.selector)") { try await $0.dropStash(stash) }
        }
    }

    func createBranch(_ id: String) {
        guard let stash = stash(id) else { return }
        let form = ActionForm(title: "Create Branch from \(RefName.stash(stash.selector))", info: "The branch starts at the commit the stash was made on. The stash is applied there and deleted afterwards.", confirm: "Create")
        form.addField(key: "name", label: LocalizedStringResource("Name", comment: "Label of a branch name field."), placeholder: "feature/…")
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            popover.close()
            runner.run(failure: "Branch not created", note: "git stash branch \(name)") { try await $0.createBranch(name, from: stash) }
        }
    }
}
