import AppKit
import GitEngine

/// Fast-forwarding the checked-out branch to a ref or commit, from the menus of refs and commits and from the command bar.
/// An entry is offered only when the target contains the branch, as far as the loaded history tells; git still refuses anything but a fast-forward.
@MainActor
final class FastForwardController {
    enum Target {
        case ref(Ref)
        case commit(String)
    }

    let viewModel: GraphViewModel
    private let prompter: ActionPrompter
    /// Says briefly what a fast-forward did, in a toast.
    var onToast: ((RefString) -> Void)?

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
    }

    // MARK: Menu

    /// "Fast-Forward main to dev" for the checked-out branch, when the target contains it. Other branches are not offered: they move with their Pull entry or after a checkout.
    func item(to target: Target) -> NSMenuItem? {
        guard let current = viewModel.currentBranch, canFastForwardCurrent(to: Self.sha(of: target)) else { return nil }
        let title: LocalizedStringResource = switch target {
        case .ref: LocalizedStringResource("checkout.choice.fastForward", defaultValue: "Fast-Forward \(RefName.branch(current)) to \(Self.name(of: target).marked)", bundle: .module)
        case .commit: LocalizedStringResource("commit.menu.fastForward", defaultValue: "Fast-Forward \(RefName.branch(current)) to this Commit", bundle: .module)
        }
        return ActionMenuItem(title) { [weak self] in self?.fastForward(to: target) }
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

    // MARK: Running

    func fastForward(to target: Target) {
        guard let branch = viewModel.currentBranch else { return }
        let repository = viewModel.repository
        let revision = Self.revision(of: target)
        let targetName = Self.name(of: target)
        Task {
            do {
                let result = try await repository.fastForwardCurrentBranch(to: revision)
                let summary = RefString(LocalizedStringResource("branch.fastForward.done", defaultValue: "Fast-forwarded \(RefName.branch(branch)) by \(result.commits) commits to \(targetName.marked)", bundle: .module))
                await viewModel.refresh(note: summary.plain + " · " + result.commandLine)
                onToast?(summary)
            } catch let error as FastForwardError {
                await viewModel.refresh(note: nil)
                let reason: LocalizedStringResource? = switch error {
                case .notFastForward: LocalizedStringResource("branch.fastForward.diverged", defaultValue: "\(RefName.branch(branch)) has commits that \(targetName.marked) does not have. Merge or rebase instead.", bundle: .module)
                case .upToDate: LocalizedStringResource("branch.fastForward.upToDate", defaultValue: "\(RefName.branch(branch)) already contains \(targetName.marked).", bundle: .module)
                case .detachedHead: nil
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

    private static func revision(of target: Target) -> String {
        switch target {
        case .ref(let ref): ref.fullName
        case .commit(let id): id
        }
    }
}
