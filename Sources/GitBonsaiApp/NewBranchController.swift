import AppKit
import GitEngine

/// The "new branch" sheet of the Local header's plus and the toolbar's Branch button: a name, a start point, and what happens after creating it.
@MainActor
final class NewBranchController {
    /// What happens once the branch exists; the raw values are the sheet's choice values.
    enum Follow: String {
        case stay, checkout, worktree
    }

    private let runner: SidebarActionRunner
    private var viewModel: GraphViewModel { runner.viewModel }

    init(runner: SidebarActionRunner) {
        self.runner = runner
    }

    /// `startPoint` preselects where the branch starts; HEAD when nil.
    func show(startPoint: String? = nil) {
        let form = ActionForm(title: "Neuer Branch", info: "Startpunkt ist ein Branch, ein Tag oder ein Commit.", confirm: "Anlegen")
        form.addField(key: "name", label: "Name", placeholder: "feature/…")
        form.addComboField(key: "start", label: "Startpunkt", value: startPoint ?? "HEAD", suggestions: ["HEAD"] + startPointSuggestions())
        form.addChoice(key: "follow", label: "Danach", options: [
            (Follow.checkout.rawValue, "Branch auschecken"),
            (Follow.worktree.rawValue, "Als neuen Worktree anlegen"),
            (Follow.stay.rawValue, "Nur anlegen"),
        ], selected: Follow.checkout.rawValue)
        form.addField(key: "path", label: "Ordner des Worktrees (leer: neben dem Repository)", required: false)
        Task {
            guard let values = await runner.prompter.ask(form), let name = values.value("name") else { return }
            let start = values.value("start") ?? "HEAD"
            switch Follow(rawValue: values.text["follow"] ?? "") ?? .checkout {
            case .stay:
                await runner.run(failure: "Branch nicht angelegt", note: "git branch") { try await $0.createBranch(name, at: start, checkout: false) }
            case .checkout:
                await runner.run(failure: "Branch nicht angelegt", note: "git switch -c") { try await $0.createBranch(name, at: start, checkout: true) }
            case .worktree:
                let folder = values.value("path").map { ($0 as NSString).expandingTildeInPath } ?? runner.defaultWorktreePath(suffix: name)
                await runner.run(failure: "Worktree nicht angelegt", note: "git worktree add -b") { try await $0.addWorktree(at: folder, commit: start, newBranch: name) }
            }
        }
    }

    /// Local branches first, then remote branches and tags.
    private func startPointSuggestions() -> [String] {
        let refs = viewModel.refs
        let locals = refs.filter { $0.kind == .localBranch }.map(\.name).sorted()
        let remotes = refs.filter { if case .remoteBranch = $0.kind { !$0.name.hasSuffix("/HEAD") } else { false } }.map(\.name).sorted()
        let tags = refs.filter { $0.kind == .tag }.map(\.name).sorted()
        return locals + remotes + tags
    }
}
