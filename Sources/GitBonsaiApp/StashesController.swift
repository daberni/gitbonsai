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
        popover = PanelPopover(list: PanelListView(title: "Stashes", empty: "Keine Stashes", noMatch: "Keine passenden Stashes", filterPlaceholder: "Stashes filtern"))
        let list = popover.list
        list.onSelect = { [weak self] id in self?.onNavigate?(id) }
        list.onActivate = { [weak self] id in self?.showDiff(id) }
        list.menuItems = { [weak self] id in self?.menuItems(for: id) ?? [] }
        list.actions = [
            PanelAction("Diff zeigen") { [weak self] id in self?.showDiff(id) },
            PanelAction("Apply") { [weak self] id in self?.apply(id) },
            PanelAction("Pop") { [weak self] id in self?.pop(id) },
            PanelAction("Branch …") { [weak self] id in self?.createBranch(id) },
            PanelAction("Drop …", isDestructive: true) { [weak self] id in self?.drop(id) },
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
        let detail = [stash.selector, stash.branch ?? "Detached HEAD"].joined(separator: " · ")
        return PanelRow(id: stash.commitID, glyph: .stashBowl, title: stash.text, marker: nil, tooltip: nil, detail: detail, date: stash.date, sha: String(stash.commitID.prefix(7)), searchText: stash.message)
    }

    private func stash(_ id: String) -> Stash? { viewModel.stashes.first { $0.commitID == id } }

    // MARK: Menu

    func menuItems(for id: String) -> [NSMenuItem] {
        [
            ActionMenuItem("Diff zeigen") { [weak self] in self?.showDiff(id) },
            .separator(),
            ActionMenuItem("Apply") { [weak self] in self?.apply(id) },
            ActionMenuItem("Pop") { [weak self] in self?.pop(id) },
            ActionMenuItem("Branch aus Stash anlegen …") { [weak self] in self?.createBranch(id) },
            .separator(),
            ActionMenuItem("Drop …") { [weak self] in self?.drop(id) },
        ]
    }

    // MARK: Toolbar

    /// The toolbar's Stash menu: stashing everything at once is its default; the others ask for a message or take only the staged changes.
    func stashMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all = ActionMenuItem("Alle Änderungen stashen") { [weak self] in self?.stashNow(.includingUntracked) }
        all.toolTip = StashScope.includingUntracked.commandLine + " -m „WIP auf <Branch>: <HEAD>“"
        menu.addItem(all)
        menu.addItem(ActionMenuItem("Stash mit Nachricht …") { [weak self] in self?.stashWithMessage() })
        let staged = ActionMenuItem("Nur gestagte Änderungen stashen") { [weak self] in self?.stashNow(.staged) }
        staged.toolTip = StashScope.staged.commandLine
        staged.isEnabled = hasStagedChanges
        menu.addItem(staged)
        return menu
    }

    var hasStagedChanges: Bool { !(viewModel.status?.staged.isEmpty ?? true) }

    /// Stashes without asking, under git's default style of message in the app's words; a toast offers to take it back.
    func stashNow(_ scope: StashScope) {
        Task {
            let message = await viewModel.repository.defaultStashMessage()
            await stash(message: message, scope: scope)
        }
    }

    /// Asks for a message and whether untracked files go along, then stashes.
    func stashWithMessage() {
        let form = ActionForm(title: "Änderungen stashen", info: "Alle Änderungen im Working Directory kommen in einen neuen Stash.", confirm: "Stash")
        form.addField(key: "message", label: "Nachricht (optional)", placeholder: "WIP", required: false)
        form.addCheckbox("Unversionierte Dateien einschließen", checked: true)
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
                prompter.onToast?("Nichts zu stashen", nil)
                return
            }
            prompter.onToast?("Gestasht: \(stash: created.stash.text)", ToastAction(title: "Rückgängig") { [weak self] in self?.undo(created) })
        } catch {
            await viewModel.refresh(note: nil)
            prompter.report(error, title: "Stash nicht angelegt")
        }
    }

    /// Pops the stash just made back, as long as nothing changed since; otherwise a toast says why it stays.
    private func undo(_ created: NewStash) {
        let repository = viewModel.repository
        Task {
            do {
                try await repository.undoStash(created)
                await viewModel.refresh(note: "git stash pop --index stash@{0}")
                prompter.onToast?("Stash zurückgenommen: \(stash: created.stash.text)", nil)
            } catch let error as StashUndoError {
                prompter.onToast?("Nicht rückgängig gemacht: \(Self.reason(error)); der Stash bleibt in der Liste", nil)
            } catch {
                await viewModel.refresh(note: nil)
                prompter.report(error, title: "Stash nicht zurückgenommen")
            }
        }
    }

    private static func reason(_ error: StashUndoError) -> String {
        switch error {
        case .notNewest: "inzwischen gibt es einen neueren Stash"
        case .headMoved: "HEAD hat sich inzwischen bewegt"
        case .workingTreeChanged: "das Working Directory hat sich inzwischen geändert"
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
        runner.run(failure: "Stash nicht angewendet", conflict: "Stash mit Konflikten angewendet", note: "git stash apply \(stash.selector)") { try await $0.applyStash(stash) }
    }

    func pop(_ id: String) {
        guard let stash = stash(id) else { return }
        runner.run(failure: "Stash nicht angewendet", conflict: "Stash mit Konflikten angewendet, er bleibt erhalten", note: "git stash pop \(stash.selector)") { try await $0.popStash(stash) }
    }

    func drop(_ id: String) {
        guard let stash = stash(id) else { return }
        Task {
            guard await runner.confirm("\(stash: stash.selector) droppen?", info: "„\(stash.text)“ wird gelöscht. Die Änderungen darin sind danach verloren.", button: "Drop") else { return }
            runner.run(failure: "Stash nicht gelöscht", note: "git stash drop \(stash.selector)") { try await $0.dropStash(stash) }
        }
    }

    func createBranch(_ id: String) {
        guard let stash = stash(id) else { return }
        let form = ActionForm(title: "Branch aus \(stash: stash.selector) anlegen", info: "Der Branch beginnt beim Commit, auf dem der Stash entstand. Der Stash wird dort angewendet und danach gelöscht.", confirm: "Anlegen")
        form.addField(key: "name", label: "Name", placeholder: "feature/…")
        Task {
            guard let values = await prompter.ask(form), let name = values.value("name") else { return }
            popover.close()
            runner.run(failure: "Branch nicht angelegt", note: "git stash branch \(name)") { try await $0.createBranch(name, from: stash) }
        }
    }
}
