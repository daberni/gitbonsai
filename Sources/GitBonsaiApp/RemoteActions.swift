import AppKit
import GitEngine

/// Adding a remote from the sidebar's "Add Remote…" and the menu of a remote's header: edit its name and URL, or remove it.
@MainActor
final class RemoteActions {
    private let runner: ActionRunner
    private let prompter: any Prompting
    private let viewModel: GraphViewModel
    private var repository: Repository { viewModel.repository }
    /// The sheet while it is open, for the harness.
    private(set) var sheet: RemoteSheet?

    init(context: RepositoryContext) {
        viewModel = context.model
        runner = context.runner
        prompter = context.prompter
    }

    func groups(for remote: String) -> [[MenuEntry]] {
        var edit = MenuEntry(LocalizedStringResource("sidebar.remote.menu.edit", defaultValue: "Edit Remote…", bundle: .module)) { [weak self] in self?.showEdit(remote) }
        edit.toolTip = "git remote rename / git remote set-url"
        var remove = MenuEntry(LocalizedStringResource("sidebar.remote.menu.remove", defaultValue: "Remove Remote…", bundle: .module)) { [weak self] in self?.remove(remote) }
        remove.toolTip = "git remote remove \(remote)"
        return [[edit], [remove]]
    }

    func showAdd() {
        guard sheet == nil, let parent = prompter.window else { return }
        Task {
            let existing = Set((try? await repository.remotes()) ?? [])
            let sheet = RemoteSheet(mode: .add, repository: repository, existing: existing)
            self.sheet = sheet
            let request = await sheet.run(on: parent)
            self.sheet = nil
            guard let request else { return }
            let failure = LocalizedStringResource("failure.remote.notAdded", defaultValue: "Remote not added", bundle: .module)
            guard await runner.perform(failure: failure, note: "git remote add", { try await $0.addRemote(request.name, url: request.url) }) == nil, request.fetch else { return }
            let fetch = FetchVariant.remote(request.name, prune: false)
            await runner.perform(failure: LocalizedStringResource("failure.fetch.failed", defaultValue: "Fetch failed", bundle: .module), note: fetch.commandLine) { try await $0.fetch(fetch) }
        }
    }

    func showEdit(_ remote: String) {
        guard sheet == nil, let parent = prompter.window else { return }
        Task {
            let urls = try? await repository.remoteURLs()
            let url = urls?.remotes.first { $0.name == remote }?.url ?? ""
            let existing = Set((try? await repository.remotes()) ?? [])
            let sheet = RemoteSheet(mode: .edit(name: remote, url: url), repository: repository, existing: existing)
            self.sheet = sheet
            let request = await sheet.run(on: parent)
            self.sheet = nil
            guard let request else { return }
            let failure = LocalizedStringResource("failure.remote.notChanged", defaultValue: "Remote not changed", bundle: .module)
            if request.name != remote {
                guard await runner.perform(failure: failure, note: "git remote rename", { try await $0.renameRemote(remote, to: request.name) }) == nil else { return }
            }
            if request.url != url {
                await runner.perform(failure: failure, note: "git remote set-url") { try await $0.setRemoteURL(request.name, url: request.url) }
            }
        }
    }

    func remove(_ remote: String) {
        Task {
            guard await runner.confirm(LocalizedStringResource("sidebar.remote.remove.title", defaultValue: "Remove Remote?", bundle: .module), names: RefString(marked: RefName.remote(remote)), button: LocalizedStringResource("sidebar.remote.remove.confirm", defaultValue: "Remove", bundle: .module, comment: "Button that removes the remote."), destructive: true, style: .warning) else { return }
            await runner.perform(failure: LocalizedStringResource("failure.remote.notRemoved", defaultValue: "Remote not removed", bundle: .module), note: "git remote remove") { try await $0.removeRemote(remote) }
        }
    }
}
