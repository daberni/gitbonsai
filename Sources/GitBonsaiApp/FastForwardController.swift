import AppKit
import GitEngine

/// Fast-forwarding a local branch to a ref or commit, from the menus of refs and commits and from the command bar.
/// An entry is offered only for branches the target contains, as far as the loaded history tells; git still refuses anything but a fast-forward.
@MainActor
final class FastForwardController {
    enum Target {
        case ref(Ref)
        case commit(String)
    }

    /// Branches other than the current one are listed inline up to this many; more go into a submenu.
    private static let inlineBranches = 3

    let viewModel: GraphViewModel
    private let prompter: ActionPrompter
    /// Says briefly what a fast-forward did, in a toast.
    var onToast: ((RefString) -> Void)?

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
    }

    // MARK: Menu

    /// "Fast-Forward main to dev" for the current branch, then local branches checked out elsewhere or nowhere.
    /// A local branch that follows a remote target is left to its Pull entry, which does the same with a fresh fetch.
    func items(to target: Target) -> [NSMenuItem] {
        let sha = Self.sha(of: target)
        let reachable = reachable(from: sha)
        let current = viewModel.currentBranch
        var items: [NSMenuItem] = []
        if let current, canFastForwardCurrent(to: sha) { items.append(item(current, to: target)) }
        let others = viewModel.refs.filter { ref in
            guard ref.kind == .localBranch, ref.name != current else { return false }
            if case .ref(let remote) = target, ref.upstream == remote.name { return false }
            return CommandRules.fastForward(branchHead: ref.target, target: sha, reachableFromTarget: reachable) == nil
        }
        let branchItems = others.map { item($0.name, to: target) }
        guard branchItems.count > Self.inlineBranches else { return items + branchItems }
        let more = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        more.setTitle(LocalizedStringResource("branch.menu.fastForwardOther", defaultValue: "Fast-Forward other Branch to \(Self.name(of: target).marked)", bundle: .module))
        more.submenu = NSMenu()
        branchItems.forEach(more.submenu!.addItem)
        return items + [more]
    }

    /// Whether the checked-out branch is a strict ancestor of `sha`; merging or rebasing onto it would only fast-forward then.
    func canFastForwardCurrent(to sha: String) -> Bool {
        guard viewModel.currentBranch != nil, let head = viewModel.headSHA else { return false }
        return CommandRules.fastForward(branchHead: head, target: sha, reachableFromTarget: reachable(from: sha)) == nil
    }

    /// One menu asks for the same target several times; the walk is linear in the loaded history, so its result is kept until the history changes.
    private func reachable(from sha: String) -> Set<String> {
        let key = ReachableKey(target: sha, commits: viewModel.history.commitCount, refresh: viewModel.appliedRefresh, generation: viewModel.loadGeneration)
        if let cached = reachableCache, cached.key == key { return cached.set }
        let set = viewModel.history.reachable(from: sha)
        reachableCache = (key, set)
        return set
    }

    private struct ReachableKey: Equatable {
        let target: String
        let commits: Int
        let refresh: Int
        let generation: Int
    }

    private var reachableCache: (key: ReachableKey, set: Set<String>)?

    private func item(_ branch: String, to target: Target) -> NSMenuItem {
        let title: LocalizedStringResource = switch target {
        case .ref: LocalizedStringResource("checkout.choice.fastForward", defaultValue: "Fast-Forward \(RefName.branch(branch)) to \(Self.name(of: target).marked)", bundle: .module)
        case .commit: LocalizedStringResource("commit.menu.fastForward", defaultValue: "Fast-Forward \(RefName.branch(branch)) to this Commit", bundle: .module)
        }
        return ActionMenuItem(title) { [weak self] in self?.fastForward(branch, to: target) }
    }

    // MARK: Running

    func fastForward(_ branch: String, to target: Target) {
        let repository = viewModel.repository
        let source = Self.source(of: target)
        let targetName = Self.name(of: target)
        Task {
            do {
                let result = try await repository.fastForward(branch, to: source)
                let summary = RefString(LocalizedStringResource("branch.fastForward.done", defaultValue: "Fast-forwarded \(RefName.branch(branch)) by \(result.commits) commits to \(targetName.marked)", bundle: .module))
                await viewModel.refresh(note: summary.plain + " · " + result.commandLine)
                onToast?(summary)
            } catch let error as FastForwardError {
                await viewModel.refresh(note: nil)
                let reason: LocalizedStringResource = switch error {
                case .notFastForward: LocalizedStringResource("branch.fastForward.diverged", defaultValue: "\(RefName.branch(branch)) has commits that \(targetName.marked) does not have. Merge or rebase instead.", bundle: .module)
                case .upToDate: LocalizedStringResource("branch.fastForward.upToDate", defaultValue: "\(RefName.branch(branch)) already contains \(targetName.marked).", bundle: .module)
                }
                prompter.report(error, title: Self.failure(branch), summary: reason)
            } catch {
                await viewModel.refresh(note: nil)
                prompter.report(error, title: Self.failure(branch))
            }
        }
    }

    private static func failure(_ branch: String) -> LocalizedStringResource {
        LocalizedStringResource("failure.fastForward.failed", defaultValue: "\(RefName.branch(branch)) not fast-forwarded", bundle: .module)
    }

    // MARK: Targets

    static func sha(of target: Target) -> String {
        switch target {
        case .ref(let ref): ref.target
        case .commit(let id): id
        }
    }

    static func name(of target: Target) -> RefString {
        switch target {
        case .ref(let ref): RefString(marked: RefMenus.pillName(of: ref))
        case .commit(let id): RefString(marked: RefName.commit(id))
        }
    }

    private static func source(of target: Target) -> FastForwardSource {
        switch target {
        case .ref(let ref):
            switch ref.kind {
            case .remoteBranch(let remote): .remote(remote: remote, branch: String(ref.name.dropFirst(remote.count + 1)))
            default: .local(ref.fullName)
            }
        case .commit(let id): .local(id)
        }
    }
}
