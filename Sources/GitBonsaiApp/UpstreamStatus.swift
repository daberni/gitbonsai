import GitEngine

/// The checked-out branch's upstream, the configured pull default and the remotes, read again on every change of the tab, so pull and push menus are built without waiting for git.
@MainActor
final class UpstreamStatus {
    private let viewModel: GraphViewModel
    private(set) var branch: String?
    private(set) var upstream: Upstream?
    private(set) var defaultMode: PullMode = .fastForwardOnly
    private(set) var remotes: [String] = []
    /// Called after a refresh, to update the toolbar.
    var onChange: (() -> Void)?
    /// Each refresh starts a new read; only the latest one may change the state.
    private var generation = 0

    init(model: GraphViewModel) {
        viewModel = model
    }

    var canPull: Bool { branch != nil && !remotes.isEmpty }
    var canPush: Bool { branch != nil && !remotes.isEmpty }
    /// A branch that could be pushed but has no upstream yet; the Push button marks it.
    var lacksUpstream: Bool { canPush && upstream == nil }

    /// The returned task ends once the state is read, for a caller that pulls right after a checkout.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        generation += 1
        let current = generation
        let repository = viewModel.repository
        let branch = viewModel.currentBranch
        return Task {
            async let upstream: Upstream? = if let branch { await repository.upstream(of: branch) } else { nil }
            async let mode = repository.defaultPullMode()
            async let remotes = (try? repository.remotes()) ?? []
            let state = await (upstream, mode, remotes)
            guard current == generation else { return }
            self.branch = branch
            (self.upstream, defaultMode, self.remotes) = state
            onChange?()
        }
    }

    /// The remote of a local branch's upstream, the longest matching name so remotes with slashes resolve; nil when no known remote matches.
    func remote(ofUpstream upstream: String) -> String? {
        remotes.filter { upstream.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }
}
