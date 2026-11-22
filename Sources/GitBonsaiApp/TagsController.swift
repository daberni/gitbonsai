import AppKit
import GitEngine

/// The Tags popover of the sidebar and what can be done with a tag: jump to its commit, check it out, push it, delete it here or on a remote, copy its name.
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
    private(set) var tags: [Tag] = []
    private(set) var remotes: [String] = []

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
        popover = PanelPopover(list: PanelListView(title: "Tags", empty: "Keine Tags", filterPlaceholder: "Tags filtern"))
        let list = popover.list
        list.onSelect = { [weak self] name in self?.jump(to: name) }
        list.onActivate = { [weak self] name in
            self?.jump(to: name)
            self?.popover.close()
        }
        list.menuItems = { [weak self] name in self?.menuItems(for: name) ?? [] }
        list.actions = [
            PanelAction("Auschecken") { [weak self] name in self?.checkout(name) },
            PanelAction("Pushen", isEnabled: { [weak self] _ in self?.remotes.isEmpty == false }) { [weak self] name in self?.pushFromButton(name) },
            PanelAction("Löschen …", isDestructive: true) { [weak self] name in self?.deleteLocally(name) },
            PanelAction("Name kopieren") { name in ActionRunner.copy(name) },
        ]
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

    func reload() async {
        let repository = viewModel.repository
        async let loadedTags = try? repository.tags()
        async let loadedRemotes = try? repository.remoteNames()
        tags = await loadedTags ?? []
        remotes = await loadedRemotes ?? []
        popover.list.show(tags.map(Self.row))
        popover.fitContent()
    }

    private static func row(_ tag: Tag) -> PanelRow {
        PanelRow(id: tag.name, glyph: .tag, title: tag.name, marker: tag.isAnnotated ? "◆" : nil, markerTooltip: tag.isAnnotated ? "Annotierter Tag" : nil, detail: tag.subject, date: tag.date, sha: String(tag.commitID.prefix(7)), searchText: tag.subject)
    }

    private func tag(_ name: String) -> Tag? { tags.first { $0.name == name } }

    // MARK: Menu

    func menuItems(for name: String) -> [NSMenuItem] {
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

    /// With one remote the button pushes there; with several it asks which one in a menu below itself.
    private func pushFromButton(_ name: String) {
        guard remotes.count > 1, let button = popover.list.footerButtons.first(where: { $0.title == "Pushen" }) else {
            if let remote = remotes.first { push(name, to: remote) }
            return
        }
        let menu = NSMenu()
        for remote in remotes { menu.addItem(ActionMenuItem("Nach „\(remote)“") { [weak self] in self?.push(name, to: remote) }) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + Theme.Space.xs), in: button)
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
