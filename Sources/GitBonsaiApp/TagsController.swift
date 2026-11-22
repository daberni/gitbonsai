import AppKit
import GitEngine

/// The Tags popover of the sidebar and what can be done with a tag: jump to its commit, check it out, push it, fetch one that is only on a remote, delete it here or on a remote, copy its name.
/// Each tag is marked by where it exists, once the remotes answered; see `TagRows`.
@MainActor
final class TagsController {
    /// Selects a commit in the history.
    var onNavigate: ((String) -> Void)?
    /// Checks a commit out through the tab's checkout flow, which deals with local changes.
    var onCheckout: ((CheckoutTarget) -> Void)?
    let prompter = ActionPrompter()
    let popover: PanelPopover
    private let viewModel: GraphViewModel
    private var runner: ActionRunner { ActionRunner(viewModel: viewModel, prompter: prompter) }
    private let remoteTags = RemoteTagCache()
    private(set) var tags: [Tag] = []
    private(set) var remotes: [String] = []
    private var localTargets: [String: TagTarget] = [:]
    private(set) var rows = TagRows(tags: [], remotes: [])

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
        popover = PanelPopover(list: PanelListView(title: "Tags", empty: "Keine Tags", filterPlaceholder: "Tags filtern"))
        let list = popover.list
        list.onSelect = { [weak self] name in self?.jump(to: name) }
        list.onActivate = { [weak self] name in
            guard self?.tag(name) != nil else { return }
            self?.jump(to: name)
            self?.popover.close()
        }
        list.menuItems = { [weak self] name in self?.menuItems(for: name) ?? [] }
        // A tag only on a remote can only be fetched; the buttons for a local tag make room for "Holen".
        let isLocal: (String?) -> Bool = { [weak self] name in name.map { self?.tag($0) != nil } ?? true }
        list.actions = [
            PanelAction("Auschecken", isShown: isLocal) { [weak self] name in self?.checkout(name) },
            PanelAction("Pushen", isEnabled: { [weak self] _ in self?.remotes.isEmpty == false }, isShown: isLocal) { [weak self] name in self?.pushFromButton(name) },
            PanelAction("Holen", isShown: { !isLocal($0) }) { [weak self] name in self?.fetchFromButton(name) },
            PanelAction("Löschen …", isDestructive: true, isShown: isLocal) { [weak self] name in self?.deleteLocally(name) },
            PanelAction("Name kopieren") { name in ActionRunner.copy(name) },
        ]
        remoteTags.onChange = { [weak self] in self?.render() }
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        Task {
            await reload()
            popover.show(relativeTo: rect, of: view)
        }
    }

    /// Called whenever the tab refreshed; an open list follows.
    func viewModelChanged() {
        guard popover.isShown else { return }
        Task { await reload() }
    }

    /// Reads the local tags and asks the remotes whose answer is missing or stale; their marks follow when they answer.
    func reload() async {
        let repository = viewModel.repository
        async let loadedTags = try? repository.tags()
        async let loadedRemotes = try? repository.remoteNames()
        async let loadedTargets = try? repository.localTagTargets()
        tags = await loadedTags ?? []
        remotes = await loadedRemotes ?? []
        localTargets = await loadedTargets ?? [:]
        await remoteTags.refresh(repository: repository, remotes: remotes)
        render()
    }

    private func render() {
        rows = TagRows(tags: tags, remotes: remotes, states: remoteTags.states(for: remotes, local: localTargets))
        let list = popover.list
        list.scopes = rows.scopes
        list.note = remoteTags.note(for: remotes)
        list.show(rows.rows)
        popover.fitContent()
    }

    /// No remote is still being asked.
    var isSettled: Bool { !remoteTags.lookups.values.contains { if case .loading = $0 { true } else { false } } }

    private func tag(_ name: String) -> Tag? { tags.first { $0.name == name } }

    // MARK: Menu

    func menuItems(for name: String) -> [NSMenuItem] {
        guard tag(name) != nil else {
            let fetches = rows.remotesOnlyHaving(name).map { remote in ActionMenuItem("Von „\(remote)“ holen") { [weak self] in self?.fetch(name, from: remote) } }
            let deletes = rows.remotesOnlyHaving(name).map { remote in ActionMenuItem("Auf „\(remote)“ löschen …") { [weak self] in self?.deleteRemotely(name, on: remote) } }
            return fetches + [NSMenuItem.separator()] + deletes + [NSMenuItem.separator(), ActionMenuItem("Name kopieren") { ActionRunner.copy(name) }]
        }
        var groups: [[NSMenuItem]] = [[
            ActionMenuItem("Zum Commit springen") { [weak self] in self?.jump(to: name) },
            ActionMenuItem("Auschecken (Detached HEAD)") { [weak self] in self?.checkout(name) },
        ]]
        groups.append(remotes.map { remote in ActionMenuItem("Nach „\(remote)“ pushen") { [weak self] in self?.push(name, to: remote) } })
        groups.append([ActionMenuItem("Löschen …") { [weak self] in self?.deleteLocally(name) }] + remotes.map { remote in
            ActionMenuItem("Auf „\(remote)“ löschen …") { [weak self] in self?.deleteRemotely(name, on: remote) }
        })
        groups.append([ActionMenuItem("Name kopieren") { ActionRunner.copy(name) }])
        return groups.filter { !$0.isEmpty }.enumerated().flatMap { offset, group in (offset > 0 ? [NSMenuItem.separator()] : []) + group }
    }

    // MARK: Actions

    private func jump(to name: String) {
        guard let tag = tag(name) else { return }
        onNavigate?(tag.commitID)
    }

    private func checkout(_ name: String) {
        guard let tag = tag(name) else { return }
        popover.close()
        onCheckout?(.commit(tag.commitID))
    }

    private func pushFromButton(_ name: String) {
        chooseRemote(from: "Pushen", among: rows.remotesPreferredForPush(name, all: remotes), title: { "Nach „\($0)“" }) { [weak self] remote in self?.push(name, to: remote) }
    }

    private func fetchFromButton(_ name: String) {
        chooseRemote(from: "Holen", among: rows.remotesOnlyHaving(name), title: { "Von „\($0)“" }) { [weak self] remote in self?.fetch(name, from: remote) }
    }

    /// With one remote the button acts at once; with several it asks which one in a menu below itself.
    private func chooseRemote(from buttonTitle: String, among candidates: [String], title: (String) -> String, perform: @escaping (String) -> Void) {
        guard candidates.count > 1, let button = popover.list.footerButtons.first(where: { $0.title == buttonTitle }) else {
            if let remote = candidates.first { perform(remote) }
            return
        }
        let menu = NSMenu()
        for remote in candidates { menu.addItem(ActionMenuItem(title(remote)) { perform(remote) }) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + Theme.Space.xs), in: button)
    }

    func fetch(_ name: String, from remote: String) {
        runner.run(failure: "Tag nicht geholt", note: "git fetch --no-tags \(remote) refs/tags/\(name):refs/tags/\(name)") { try await $0.fetchTag(name, from: remote) }
    }

    func push(_ name: String, to remote: String) {
        runner.run(failure: "Tag nicht gepusht", note: "git push \(remote) refs/tags/\(name)") { try await $0.pushTag(name, to: remote) }
    }

    func deleteLocally(_ name: String) {
        Task {
            guard await runner.confirm("Tag „\(name)“ löschen?", info: "Der Tag wird in diesem Repository gelöscht. Der Commit und Tags auf Remotes bleiben.", button: "Löschen") else { return }
            runner.run(failure: "Tag nicht gelöscht", note: "git tag --delete \(name)") { try await $0.deleteTag(name) }
        }
    }

    func deleteRemotely(_ name: String, on remote: String) {
        Task {
            guard await runner.confirm("Tag „\(name)“ auf „\(remote)“ löschen?", info: "Der Tag verschwindet für alle, die von „\(remote)“ holen. Der lokale Tag bleibt.", button: "Auf \(remote) löschen") else { return }
            runner.run(failure: "Tag auf „\(remote)“ nicht gelöscht", note: "git push \(remote) --delete refs/tags/\(name)") { try await $0.deleteRemoteTag(name, on: remote) }
        }
    }
}
