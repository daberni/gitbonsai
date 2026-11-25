import AppKit
import GitEngine

/// Pushing: the checked-out branch to its upstream or a first push that sets one, any local branch from its menu, and tags. A rejected push offers to pull first or to overwrite with `--force-with-lease`.
@MainActor
final class PushUseCase {
    let prompter: any Prompting
    private let viewModel: GraphViewModel
    let status: UpstreamStatus
    private let pullUseCase: PullUseCase

    init(context: RepositoryContext, status: UpstreamStatus, pull: PullUseCase) {
        viewModel = context.model
        prompter = context.prompter
        self.status = status
        pullUseCase = pull
    }

    private var branch: String? { status.branch }
    private var upstream: Upstream? { status.upstream }
    private var remotes: [String] { status.remotes }

    // MARK: Menus

    /// Pushing the branch to its upstream, or the first push that sets one; then the tags for each remote.
    func groups() -> [[MenuEntry]] {
        var branchEntry: MenuEntry
        if let branch, let upstream {
            let variant = PushVariant.branch(branch, remote: upstream.remote, remoteBranch: upstream.branch, setUpstream: false, forceWithLease: false)
            branchEntry = MenuEntry(LocalizedStringResource("push.menu.branch", defaultValue: "Push \(RefName.branch(branch)) to \(RefName.remoteBranch(upstream.name))", bundle: .module)) { [weak self] in self?.push(variant, upstream: upstream.name) }
            branchEntry.toolTip = variant.commandLine
        } else {
            branchEntry = MenuEntry(branch.map { name -> LocalizedStringResource in LocalizedStringResource("push.menu.setUpstream", defaultValue: "Push \(RefName.branch(name)) and Set Upstream…", bundle: .module) } ?? LocalizedStringResource("push.menu.headSetUpstream", defaultValue: "Push HEAD and Set Upstream…", bundle: .module)) { [weak self] in self?.firstPush() }
            branchEntry.disabledReason = status.pushBlocked
        }
        let tags = remotes.map { remote in
            let variant = PushVariant.tags(remote: remote)
            var entry = MenuEntry(LocalizedStringResource("push.menu.tags", defaultValue: "Push Tags to \(RefName.remote(remote))", bundle: .module)) { [weak self] in self?.pushTags(variant) }
            entry.toolTip = variant.commandLine
            return entry
        }
        return [[branchEntry], tags]
    }

    /// "Push <branch>" to its upstream for a local branch with an upstream on a known remote, "Push <branch>…" with the first-push sheet for one without upstream, nil for anything else. A rejected push offers the same ways out as the toolbar's.
    func entry(for ref: Ref) -> MenuEntry? {
        guard ref.kind == .localBranch else { return nil }
        let name = ref.name
        guard let upstream = ref.upstream else {
            guard !remotes.isEmpty else { return nil }
            var entry = MenuEntry(LocalizedStringResource("branch.menu.pushSetUpstream", defaultValue: "Push \(RefName.branch(name))…", bundle: .module)) { [weak self] in self?.firstPush(of: name) }
            entry.toolTip = "git push -u"
            return entry
        }
        guard let remote = status.remote(ofUpstream: upstream) else { return nil }
        let remoteBranch = String(upstream.dropFirst(remote.count + 1))
        return MenuEntry(LocalizedStringResource("branch.menu.push", defaultValue: "Push \(RefName.branch(name))", bundle: .module)) { [weak self] in
            self?.push(.branch(name, remote: remote, remoteBranch: remoteBranch, setUpstream: false, forceWithLease: false), upstream: upstream)
        }
    }

    // MARK: Push

    /// A rejection because the remote has other commits offers to pull first and push again, or to overwrite with `--force-with-lease`, which still refuses when the remote moved since the last fetch.
    func push(_ variant: PushVariant, upstream: String) {
        run(variant, failure: LocalizedStringResource("failure.push.failed", defaultValue: "Push failed", bundle: .module)) { [weak self] error in
            guard let self, error.isRejectedNonFastForward, case .branch(let branch, let remote, let remoteBranch, let setUpstream, false) = variant else { return false }
            let force = PushVariant.branch(branch, remote: remote, remoteBranch: remoteBranch, setUpstream: setUpstream, forceWithLease: true)
            let canPullFirst = branch == self.branch && self.upstream?.name == upstream
            var actions: [FailureAction] = []
            if canPullFirst {
                actions.append(FailureAction(title: LocalizedStringResource("push.rejected.pullAndPush", defaultValue: "Pull and Push again", bundle: .module)) { [weak self] in
                    guard let self else { return }
                    Task {
                        guard await self.pullUseCase.performPull(PullVariant(mode: self.status.defaultMode)) else { return }
                        self.push(variant, upstream: upstream)
                    }
                })
            }
            actions.append(FailureAction(title: LocalizedStringResource("push.rejected.force", defaultValue: "Overwrite with --force-with-lease", bundle: .module), isDestructive: true) { [weak self] in self?.forcePush(force, upstream: upstream) })
            prompter.report(error, title: LocalizedStringResource("failure.push.rejected", defaultValue: "Push rejected", bundle: .module), summary: LocalizedStringResource("push.rejected.summary", defaultValue: "\(RefName.remoteBranch(upstream)) has commits that \(RefName.branch(branch)) lacks. Pull them first, or overwrite them with --force-with-lease.", bundle: .module), actions: actions)
            return true
        }
    }

    private func forcePush(_ variant: PushVariant, upstream: String) {
        run(variant, failure: LocalizedStringResource("failure.push.forceFailed", defaultValue: "Force push failed", bundle: .module)) { [weak self] error in
            guard let self, error.isStaleLease else { return false }
            // The history shows what is new on the remote, so nothing is overwritten unseen; the status line names the fetch.
            if case .branch(_, let remote, _, _, _) = variant { _ = await viewModel.fetch(.remote(remote, prune: false)) }
            prompter.report(error, title: LocalizedStringResource("failure.push.forceRejected", defaultValue: "Force push rejected", bundle: .module), summary: LocalizedStringResource("push.forceRejected.summary", defaultValue: "\(RefName.remoteBranch(upstream)) has new commits. They are fetched and shown in the history.", bundle: .module))
            return true
        }
    }

    /// The sheet of the first push of `branch`, the checked-out one by default: the remote (origin when there is one) and the branch's name there; the push sets the upstream.
    func firstPush(of branch: String? = nil) {
        guard let branch = branch ?? self.branch, !remotes.isEmpty else { return }
        let form = ActionForm(title: LocalizedStringResource("push.setUpstream.title", defaultValue: "Push \(RefName.branch(branch))", bundle: .module), confirm: LocalizedStringResource("push.setUpstream.confirm", defaultValue: "Push Branch", bundle: .module))
        form.addChoice(key: "remote", label: LocalizedStringResource("push.setUpstream.remote", defaultValue: "Remote", bundle: .module, comment: "Field label: the remote to push to."), options: remotes.map { ($0, .verbatim($0)) }, selected: remotes.contains("origin") ? "origin" : remotes[0])
        form.addField(key: "name", label: LocalizedStringResource("push.setUpstream.remoteName", defaultValue: "Branch on the remote", bundle: .module), value: branch)
        Task {
            guard let values = await prompter.ask(form), let remote = values.text["remote"], let name = values.value("name") else { return }
            push(.branch(branch, remote: remote, remoteBranch: name, setUpstream: true, forceWithLease: false), upstream: "\(remote)/\(name)")
        }
    }

    func pushTags(_ variant: PushVariant) {
        run(variant, failure: LocalizedStringResource("failure.push.tagsNotPushed", defaultValue: "Tags not pushed", bundle: .module)) { _ in false }
    }

    /// Runs a push and refreshes the tab. `handle` may take over a failure and returns true when it did; otherwise git's message is shown.
    private func run(_ variant: PushVariant, failure: LocalizedStringResource, handle: @escaping (GitError) async -> Bool) {
        let repository = viewModel.repository
        Task {
            await viewModel.remoteActivity.run(.push) { [self] in await pushAndRefresh(variant, repository: repository, failure: failure, handle: handle) }
        }
    }

    private func pushAndRefresh(_ variant: PushVariant, repository: Repository, failure: LocalizedStringResource, handle: @escaping (GitError) async -> Bool) async {
        do {
            try await Signposts.measure("push", variant.commandLine) { try await repository.push(variant) }
            await viewModel.refresh(note: variant.commandLine)
        } catch is CancellationError {
            await viewModel.refreshAfterCancel(variant.commandLine)
        } catch {
            await viewModel.refresh(note: nil)
            if let gitError = error as? GitError, await handle(gitError) { return }
            prompter.report(error, title: failure)
        }
    }
}
