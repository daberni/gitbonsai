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
        popover = PanelPopover(list: PanelListView(title: "Tags", empty: "No tags", noMatch: "No matching tags", filterPlaceholder: "Filter tags"))
        let list = popover.list
        list.onSelect = { [weak self] name in self?.jump(to: name) }
        list.onActivate = { [weak self] name in
            guard self?.tag(name) != nil else { return }
            self?.jump(to: name)
            self?.popover.close()
        }
        list.menuItems = { [weak self] name in self?.menuItems(for: name) ?? [] }
        // A tag only on a remote can only be fetched; the buttons for a local tag make room for "Fetch Tag".
        let isLocal: (String?) -> Bool = { [weak self] name in name.map { self?.tag($0) != nil } ?? true }
        list.actions = [
            PanelAction("Check Out", isShown: isLocal) { [weak self] name in self?.checkout(name) },
            PanelAction(Self.pushButton, isEnabled: { [weak self] _ in self?.remotes.isEmpty == false }, isShown: isLocal) { [weak self] name in self?.pushFromButton(name) },
            PanelAction(Self.fetchButton, isShown: { !isLocal($0) }) { [weak self] name in self?.fetchFromButton(name) },
            PanelAction("Delete…", isDestructive: true, isShown: isLocal) { [weak self] name in self?.deleteLocally(name) },
            PanelAction("Copy Tag Name") { name in ActionRunner.copy(name) },
        ]
        remoteTags.onChange = { [weak self] in self?.render() }
    }

    /// The footer buttons are found again by their title when several remotes need a menu below them.
    private static let pushButton: LocalizedStringResource = "Push Tag"
    private static let fetchButton: LocalizedStringResource = "Fetch Tag"

    func show(relativeTo rect: NSRect, of view: NSView) {
        Task {
            await reload()
            popover.show(relativeTo: rect, of: view)
        }
    }

    /// Called whenever the tab refreshed; an open list follows. The remotes are kept current for the tag pills' menus also while the list is closed.
    func viewModelChanged() {
        let repository = viewModel.repository
        Task {
            guard popover.isShown else {
                remotes = (try? await repository.remoteNames()) ?? remotes
                return
            }
            await reload()
        }
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
        list.isBusy = !isSettled
        list.show(rows.rows)
        popover.fitContent()
    }

    /// No remote is still being asked.
    var isSettled: Bool { remoteTags.pending.isEmpty }

    private func tag(_ name: String) -> Tag? { tags.first { $0.name == name } }

    // MARK: Menu

    func menuItems(for name: String) -> [NSMenuItem] {
        guard let tag = tag(name) else {
            let fetches = rows.remotesOnlyHaving(name).map { remote in ActionMenuItem("Fetch from \(RefName.remote(remote))") { [weak self] in self?.fetch(name, from: remote) } }
            let deletes = rows.remotesOnlyHaving(name).map { remote in ActionMenuItem("Delete on \(RefName.remote(remote))…") { [weak self] in self?.deleteRemotely(name, on: remote) } }
            return fetches + [NSMenuItem.separator()] + deletes + [NSMenuItem.separator(), ActionMenuItem("Copy Tag Name") { ActionRunner.copy(name) }]
        }
        let jump: [NSMenuItem] = [ActionMenuItem("Jump to Commit") { [weak self] in self?.jump(to: name) }]
        return ([jump] + localTagGroups(name, commit: tag.commitID)).joinedWithSeparators
    }

    /// The actions on a local tag at `commit`, shared by the list and the tag's pill in the history.
    func localTagGroups(_ name: String, commit: String) -> [[NSMenuItem]] {
        [
            [ActionMenuItem("Check Out (Detached HEAD)") { [weak self] in self?.checkout(commit: commit) }],
            remotes.map { remote in ActionMenuItem("Push to \(RefName.remote(remote))") { [weak self] in self?.push(name, to: remote) } },
            [ActionMenuItem("Delete…") { [weak self] in self?.deleteLocally(name) }] + remotes.map { remote in
                ActionMenuItem("Delete on \(RefName.remote(remote))…") { [weak self] in self?.deleteRemotely(name, on: remote) }
            },
            [ActionMenuItem("Copy Tag Name") { ActionRunner.copy(name) }],
        ]
    }

    // MARK: Actions

    private func jump(to name: String) {
        guard let tag = tag(name) else { return }
        onNavigate?(tag.commitID)
    }

    private func checkout(_ name: String) {
        guard let tag = tag(name) else { return }
        checkout(commit: tag.commitID)
    }

    private func checkout(commit: String) {
        popover.close()
        onCheckout?(.commit(commit))
    }

    private func pushFromButton(_ name: String) {
        chooseRemote(from: Self.pushButton, among: rows.remotesPreferredForPush(name, all: remotes), title: { "To \(RefName.remote($0))" }) { [weak self] remote in self?.push(name, to: remote) }
    }

    private func fetchFromButton(_ name: String) {
        chooseRemote(from: Self.fetchButton, among: rows.remotesOnlyHaving(name), title: { "From \(RefName.remote($0))" }) { [weak self] remote in self?.fetch(name, from: remote) }
    }

    /// With one remote the button acts at once; with several it asks which one in a menu below itself.
    private func chooseRemote(from buttonTitle: LocalizedStringResource, among candidates: [String], title: (String) -> LocalizedStringResource, perform: @escaping (String) -> Void) {
        guard candidates.count > 1, let button = popover.list.footerButtons.first(where: { $0.title == buttonTitle.text }) else {
            if let remote = candidates.first { perform(remote) }
            return
        }
        let menu = NSMenu()
        for remote in candidates { menu.addItem(ActionMenuItem(title(remote)) { perform(remote) }) }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + Theme.Space.xs), in: button)
    }

    func fetch(_ name: String, from remote: String) {
        runner.run(failure: "Tag not fetched", note: "git fetch --no-tags \(remote) refs/tags/\(name):refs/tags/\(name)") { try await $0.fetchTag(name, from: remote) }
    }

    func push(_ name: String, to remote: String) {
        runner.run(failure: "Tag not pushed", note: "git push \(remote) refs/tags/\(name)") { try await $0.pushTag(name, to: remote) }
    }

    func deleteLocally(_ name: String) {
        Task {
            guard await confirm("Delete tag \(RefName.tag(name))?", info: "The tag is deleted in this repository. The commit and tags on remotes stay.", button: "Delete") else { return }
            runner.run(failure: "Tag not deleted", note: "git tag --delete \(name)") { try await $0.deleteTag(name) }
        }
    }

    func deleteRemotely(_ name: String, on remote: String) {
        Task {
            guard await confirm("Delete tag \(RefName.tag(name)) on \(RefName.remote(remote))?", info: "The tag disappears for everyone who fetches from \(RefName.remote(remote)). The local tag stays.", button: "Delete on \(remote)") else { return }
            runner.run(failure: "Tag not deleted on \(RefName.remote(remote))", note: "git push \(remote) --delete refs/tags/\(name)") { try await $0.deleteRemoteTag(name, on: remote) }
        }
    }

    /// The list stays open behind the question and shows the outcome in place.
    private func confirm(_ title: LocalizedStringResource, info: LocalizedStringResource, button: LocalizedStringResource) async -> Bool {
        let runner = runner
        return await popover.stayingOpen { await runner.confirm(title, info: info, button: button) }
    }
}
