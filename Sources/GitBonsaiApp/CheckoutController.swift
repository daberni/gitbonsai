import AppKit
import GitEngine

/// Checking out from the history: what a row offers, and running the checkout with the questions it may raise.
@MainActor
final class CheckoutController: NSObject {
    struct Choice {
        let title: String
        let target: CheckoutTarget
        /// Set when the branch is checked out in another worktree; going there is the checkout.
        let worktreePath: String?
    }

    /// A worktree was chosen instead of a checkout.
    var onSwitchWorktree: ((String) -> Void)?
    /// The window that questions and errors are shown on.
    var window: (() -> NSWindow?)?

    private let viewModel: GraphViewModel

    init(viewModel: GraphViewModel) {
        self.viewModel = viewModel
    }

    /// What a double click or the context menu offers on a history row: its branches first, the bare commit last.
    func choices(forRow index: Int) -> [Choice] {
        guard viewModel.kinds.indices.contains(index), viewModel.kinds[index] == .commit || viewModel.kinds[index] == .merge else { return [] }
        let commit = viewModel.commits[index]
        let refs = viewModel.refsByCommit[commit.id] ?? []
        let elsewhere = viewModel.branchesInOtherWorktrees
        var choices: [Choice] = []
        var localNames: Set<String> = []
        for ref in refs where ref.kind == .localBranch && !ref.isHead {
            localNames.insert(ref.name)
            let worktree = elsewhere[ref.fullName]
            let title = worktree.map { "Zu Worktree „\(($0.path as NSString).lastPathComponent)“ wechseln (\(ref.name))" } ?? "„\(ref.name)“ auschecken"
            choices.append(Choice(title: title, target: .localBranch(ref.name), worktreePath: worktree?.path))
        }
        for ref in refs {
            guard case .remoteBranch(let remote) = ref.kind, !ref.name.hasSuffix("/HEAD") else { continue }
            let branch = String(ref.name.dropFirst(remote.count + 1))
            let hasLocalHere = localNames.contains(branch) || refs.contains { $0.kind == .localBranch && $0.name == branch }
            if !hasLocalHere { choices.append(Choice(title: "„\(ref.name)“ als lokalen Branch auschecken", target: .remoteBranch(remote: remote, branch: branch), worktreePath: nil)) }
        }
        if commit.id != viewModel.headSHA || viewModel.currentBranch != nil {
            choices.append(Choice(title: "Commit \(commit.id.prefix(7)) auschecken (Detached HEAD)", target: .commit(commit.id), worktreePath: nil))
        }
        return choices
    }

    /// A double click checks out the branch at the row. A row without a branch does nothing: a detached HEAD should be asked for, not happen by accident.
    func activate(row index: Int) {
        guard let choice = choices(forRow: index).first, choice.target != .commit(viewModel.commits[index].id) else { return }
        perform(choice)
    }

    func menuItems(forRow index: Int) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for (offset, choice) in choices(forRow: index).enumerated() {
            if case .commit = choice.target, offset > 0 { items.append(.separator()) }
            let item = NSMenuItem(title: choice.title, action: #selector(performFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = MenuChoice(choice)
            items.append(item)
        }
        return items
    }

    /// Branches from the sidebar come in here too.
    func perform(_ target: CheckoutTarget, worktreePath: String?) {
        if let worktreePath { onSwitchWorktree?(worktreePath) } else { checkout(target) }
    }

    private func perform(_ choice: Choice) {
        perform(choice.target, worktreePath: choice.worktreePath)
    }

    @objc private func performFromMenu(_ sender: NSMenuItem) {
        guard let choice = (sender.representedObject as? MenuChoice)?.choice else { return }
        perform(choice)
    }

    func checkout(_ target: CheckoutTarget, carryingChanges: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            switch await viewModel.checkout(target, carryingChanges: carryingChanges) {
            case .done:
                break
            case .blockedByLocalChanges(let message):
                let alert = NSAlert()
                alert.messageText = "Lokale Änderungen stehen dem Wechsel im Weg"
                alert.informativeText = message
                alert.addButton(withTitle: "Stashen und wechseln")
                alert.addButton(withTitle: "Abbrechen")
                present(alert) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.checkout(target, carryingChanges: true) }
                }
            case .failed(let message):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Wechsel fehlgeschlagen"
                alert.informativeText = message
                present(alert) { _ in }
            }
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        guard ScreenshotHarness.outputPath == nil, let window = window?() else {
            FileHandle.standardError.write(Data("\(alert.messageText): \(alert.informativeText)\n".utf8))
            return
        }
        alert.beginSheetModal(for: window) { response in completion(response) }
    }

    /// Menu items carry objects; this boxes a choice for one.
    private final class MenuChoice: NSObject {
        let choice: Choice
        init(_ choice: Choice) { self.choice = choice }
    }
}
