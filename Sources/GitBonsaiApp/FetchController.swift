import AppKit
import GitEngine

/// The Fetch button's menu and running the chosen variant. The status line says what ran; a failure shows git's message.
@MainActor
final class FetchController {
    let prompter: ActionPrompter
    private let viewModel: GraphViewModel
    /// The configured remotes as of the last refresh; a menu has to be built without waiting for git.
    private(set) var remotes: [String] = []

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
    }

    /// Reads the remotes again, for instance after the tab moved or a remote was added.
    func refreshRemotes() {
        let repository = viewModel.repository
        Task {
            guard let list = try? await repository.remotes(), list != remotes else { return }
            remotes = list
        }
    }

    /// All remotes first, then each remote with and without prune, then tags. Each entry shows its git command as tooltip.
    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(LocalizedStringResource("fetch.action.all", defaultValue: "Fetch all Remotes", bundle: .module), .allRemotes))
        if !remotes.isEmpty { menu.addItem(.separator()) }
        for remote in remotes {
            menu.addItem(item(LocalizedStringResource("fetch.action.remote", defaultValue: "Fetch \(RefName.remote(remote))", bundle: .module), .remote(remote, prune: false)))
            menu.addItem(item(LocalizedStringResource("fetch.action.remotePrune", defaultValue: "Fetch \(RefName.remote(remote)) and Prune deleted Branches", bundle: .module), .remote(remote, prune: true)))
        }
        menu.addItem(.separator())
        menu.addItem(item(LocalizedStringResource("fetch.action.tags", defaultValue: "Fetch Tags from all Remotes", bundle: .module), .tags))
        return menu
    }

    func fetch(_ variant: FetchVariant) {
        Task {
            if let error = await viewModel.fetch(variant) {
                prompter.report(error, title: LocalizedStringResource("failure.fetch.failed", defaultValue: "Fetch failed", bundle: .module))
            }
        }
    }

    private func item(_ title: LocalizedStringResource, _ variant: FetchVariant) -> NSMenuItem {
        let item = ActionMenuItem(title) { [weak self] in self?.fetch(variant) }
        item.toolTip = variant.commandLine
        item.isEnabled = !remotes.isEmpty
        return item
    }
}
