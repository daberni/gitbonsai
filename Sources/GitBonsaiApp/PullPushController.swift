import AppKit
import GitEngine

/// The Pull and Push buttons' menus and running their git commands for the current branch.
/// It keeps the branch's upstream and the configured pull default, read again on every change of the tab, so a menu is built without waiting for git.
@MainActor
final class PullPushController {
    let prompter: ActionPrompter
    private let viewModel: GraphViewModel
    private(set) var branch: String?
    private(set) var upstream: Upstream?
    private(set) var defaultMode: PullMode = .fastForwardOnly
    private(set) var remotes: [String] = []
    /// Called after a refresh, to update the toolbar.
    var onChange: (() -> Void)?
    /// Each refresh starts a new read; only the latest one may change the state.
    private var generation = 0

    init(viewModel: GraphViewModel, prompter: ActionPrompter) {
        self.viewModel = viewModel
        self.prompter = prompter
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

    // MARK: Menus

    /// With an upstream: the three modes, the default marked and first; every mode carries local changes. Without one: setting it.
    func pullMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let branch, let upstream else {
            menu.addItem(header(branch.map { name -> LocalizedStringResource in LocalizedStringResource("pull.menu.noUpstream", defaultValue: "\(RefName.branch(name)) has no upstream", bundle: .module) } ?? LocalizedStringResource("pull.menu.headNoUpstream", defaultValue: "HEAD has no upstream", bundle: .module)))
            let set = ActionMenuItem(LocalizedStringResource("pull.action.setUpstreamAndPull", defaultValue: "Set Upstream and Pull…", bundle: .module)) { [weak self] in self?.setUpstreamAndPull() }
            set.isEnabled = branch != nil && !remoteBranches().isEmpty
            menu.addItem(set)
            return menu
        }
        menu.addItem(header(LocalizedStringResource("pull.menu.header", defaultValue: "Pull \(RefName.remoteBranch(upstream.name)) into \(RefName.branch(branch))", bundle: .module)))
        let modes = [defaultMode] + PullMode.allCases.filter { $0 != defaultMode }
        for mode in modes {
            menu.addItem(pullItem(Self.title(of: mode, isDefault: mode == defaultMode), PullVariant(mode: mode)))
        }
        return menu
    }

    /// Pushing the branch to its upstream, or the first push that sets one; then the tags for each remote.
    func pushMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let branch, let upstream {
            let variant = PushVariant.branch(branch, remote: upstream.remote, remoteBranch: upstream.branch, setUpstream: false, forceWithLease: false)
            let item = ActionMenuItem(LocalizedStringResource("push.menu.branch", defaultValue: "Push \(RefName.branch(branch)) to \(RefName.remoteBranch(upstream.name))", bundle: .module)) { [weak self] in self?.push(variant, upstream: upstream.name) }
            item.toolTip = variant.commandLine
            menu.addItem(item)
        } else {
            let item = ActionMenuItem(branch.map { name -> LocalizedStringResource in LocalizedStringResource("push.menu.setUpstream", defaultValue: "Push \(RefName.branch(name)) and Set Upstream…", bundle: .module) } ?? LocalizedStringResource("push.menu.headSetUpstream", defaultValue: "Push HEAD and Set Upstream…", bundle: .module)) { [weak self] in self?.firstPush() }
            item.isEnabled = branch != nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for remote in remotes {
            let variant = PushVariant.tags(remote: remote)
            let item = ActionMenuItem(LocalizedStringResource("push.menu.tags", defaultValue: "Push Tags to \(RefName.remote(remote))", bundle: .module)) { [weak self] in self?.pushTags(variant) }
            item.toolTip = variant.commandLine
            menu.addItem(item)
        }
        return menu
    }

    private static func title(of mode: PullMode, isDefault: Bool) -> LocalizedStringResource {
        switch (mode, isDefault) {
        case (.fastForwardOnly, false): LocalizedStringResource("pull.menu.fastForwardOnly", defaultValue: "Fast-forward only", bundle: .module)
        case (.fastForwardOnly, true): LocalizedStringResource("pull.menu.fastForwardOnlyDefault", defaultValue: "Fast-forward only (default)", bundle: .module)
        case (.merge, false): LocalizedStringResource("pull.mode.merge", defaultValue: "Merge", bundle: .module, comment: "Pull mode.")
        case (.merge, true): LocalizedStringResource("pull.menu.mergeDefault", defaultValue: "Merge (default)", bundle: .module)
        case (.rebase, false): LocalizedStringResource("pull.mode.rebase", defaultValue: "Rebase", bundle: .module, comment: "Pull mode.")
        case (.rebase, true): LocalizedStringResource("pull.menu.rebaseDefault", defaultValue: "Rebase (default)", bundle: .module)
        }
    }

    private func header(_ title: LocalizedStringResource) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.setTitle(title)
        item.isEnabled = false
        return item
    }

    private func pullItem(_ title: LocalizedStringResource, _ variant: PullVariant) -> NSMenuItem {
        let item = ActionMenuItem(title) { [weak self] in self?.pull(variant) }
        item.toolTip = variant.commandLine
        return item
    }

    // MARK: Pull

    func pull(_ variant: PullVariant) {
        Task { await performPull(variant) }
    }

    /// Pulls and refreshes the tab; true when the pull went through. Local changes come along through `--autostash`: when they conflict on the way back, the working directory shows the conflicts, and the status line and a toast say so, without a sheet.
    @discardableResult
    func performPull(_ variant: PullVariant) async -> Bool {
        let repository = viewModel.repository
        let upstreamName = upstream?.name ?? String(localized: "pull.diverged.upstreamName", defaultValue: "Upstream", bundle: .module, comment: "Stands for the upstream branch when its name is unknown.")
        do {
            let result = try await repository.pull(variant)
            await viewModel.refresh(note: variant.commandLine + (result.localChangesConflicted ? " · " + Self.conflictedChanges : ""))
            if result.localChangesConflicted { prompter.onToast?(RefString(LocalizedStringResource("pull.toast.doneWithConflicts", defaultValue: "Pull done, local changes brought back with conflicts, stash “autostash” stays", bundle: .module)), prompter.onShowConflicts.map { show in ToastAction(title: LocalizedStringResource("failure.toast.showConflicts", defaultValue: "Show conflicts", bundle: .module)) { show() } }) }
            return true
        } catch let error as GitError where error.isDivergedPull {
            await viewModel.refresh(note: nil)
            await offerRebase(after: error, upstream: upstreamName)
        } catch {
            await viewModel.refresh(note: nil)
            let stopped = (error as? GitError)?.stoppedOnConflict == true
            await prompter.report(error, title: stopped ? LocalizedStringResource("failure.pull.conflicts", defaultValue: "Pull stopped on conflicts", bundle: .module) : LocalizedStringResource("failure.pull.failed", defaultValue: "Pull failed", bundle: .module), unlessStoppedIn: repository)
        }
        return false
    }

    /// The status line after a pull whose carried changes conflicted on the way back.
    static let conflictedChanges = String(localized: "pull.toast.conflictedChanges", defaultValue: "local changes brought back with conflicts, stash “autostash” stays", bundle: .module, comment: "Status line after a pull, after the git command.")

    /// A fast-forward-only pull found commits on both sides; the local ones can go on top of the upstream, or the two can be merged.
    /// The pull fetched first, so the counts are read again rather than taken from before it.
    private func offerRebase(after error: GitError, upstream: String) async {
        let fresh: Upstream? = if let branch { await viewModel.repository.upstream(of: branch) } else { nil }
        let summary: LocalizedStringResource = if let ahead = fresh?.ahead, let behind = fresh?.behind {
            LocalizedStringResource("pull.diverged.infoCounts", defaultValue: "Local commits: \(ahead), new commits on \(RefName.remoteBranch(upstream)): \(behind). A fast-forward is not possible. Rebase puts the local commits on top of \(RefName.remoteBranch(upstream)), merge joins both sides with a merge commit.", bundle: .module)
        } else {
            LocalizedStringResource("pull.diverged.info", defaultValue: "A fast-forward is not possible. Rebase puts the local commits on top of \(RefName.remoteBranch(upstream)), merge joins both sides with a merge commit.", bundle: .module)
        }
        prompter.showSheet(title: LocalizedStringResource("pull.diverged.title", defaultValue: "Branches have diverged", bundle: .module), summary: summary, details: GitFailureText.details(of: error), actions: [
            FailureAction(title: LocalizedStringResource("pull.diverged.rebase", defaultValue: "Pull using rebase", bundle: .module)) { [weak self] in self?.pull(PullVariant(mode: .rebase)) },
            FailureAction(title: LocalizedStringResource("pull.diverged.merge", defaultValue: "Pull using merge", bundle: .module)) { [weak self] in self?.pull(PullVariant(mode: .merge)) },
        ])
    }

    /// Asks for a remote branch, makes it the upstream and pulls with the default mode.
    func setUpstreamAndPull() {
        guard let branch else { return }
        let candidates = remoteBranches()
        let preferred = candidates.first { $0 == "origin/\(branch)" } ?? candidates.first { $0.hasSuffix("/\(branch)") } ?? candidates.first ?? ""
        let form = ActionForm(title: LocalizedStringResource("pull.setUpstream.title", defaultValue: "Set Upstream for \(RefName.branch(branch))", bundle: .module), info: LocalizedStringResource("pull.setUpstream.info", defaultValue: "\(RefName.branch(branch)) has no upstream. The chosen remote branch becomes its upstream, then it is pulled from.", bundle: .module), confirm: LocalizedStringResource("pull.setUpstream.confirm", defaultValue: "Set and Pull", bundle: .module))
        form.addComboField(key: "upstream", label: LocalizedStringResource("pull.setUpstream.field", defaultValue: "Upstream", bundle: .module, comment: "Field label: the upstream branch."), value: preferred, suggestions: candidates)
        Task {
            guard let values = await prompter.ask(form), let upstream = values.value("upstream") else { return }
            do {
                try await viewModel.repository.setUpstream(of: branch, to: upstream)
            } catch {
                prompter.report(error, title: LocalizedStringResource("failure.upstream.notSet", defaultValue: "Upstream not set", bundle: .module))
                return
            }
            pull(PullVariant(mode: defaultMode))
        }
    }

    func remoteBranches() -> [String] {
        viewModel.refs.filter { if case .remoteBranch = $0.kind { !$0.name.hasSuffix("/HEAD") } else { false } }.map(\.name).sorted()
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
                        guard await self.performPull(PullVariant(mode: self.defaultMode)) else { return }
                        self.push(variant, upstream: upstream)
                    }
                })
            }
            actions.append(FailureAction(title: LocalizedStringResource("push.rejected.force", defaultValue: "Overwrite with --force-with-lease", bundle: .module), isDestructive: true) { [weak self] in self?.forcePush(force, upstream: upstream) })
            prompter.report(error, title: LocalizedStringResource("failure.push.rejected", defaultValue: "Push rejected", bundle: .module), summary: LocalizedStringResource("push.rejected.summary", defaultValue: "\(RefName.remoteBranch(upstream)) has commits that \(RefName.branch(branch)) lacks. Pulling brings them in first; --force-with-lease overwrites them as long as \(RefName.remoteBranch(upstream)) has not moved since the last fetch.", bundle: .module), actions: actions)
            return true
        }
    }

    private func forcePush(_ variant: PushVariant, upstream: String) {
        run(variant, failure: LocalizedStringResource("failure.push.forceFailed", defaultValue: "Force push failed", bundle: .module)) { [weak self] error in
            guard error.isStaleLease else { return false }
            self?.prompter.report(error, title: LocalizedStringResource("failure.push.forceRejected", defaultValue: "Force push rejected", bundle: .module), summary: LocalizedStringResource("push.forceRejected.summary", defaultValue: "\(RefName.remoteBranch(upstream)) has moved since the last fetch. Fetch first and check what is new there.", bundle: .module))
            return true
        }
    }

    /// The sheet of the first push: the remote (origin when there is one) and the branch's name there; the push sets the upstream.
    func firstPush() {
        guard let branch, !remotes.isEmpty else { return }
        let form = ActionForm(title: LocalizedStringResource("push.setUpstream.title", defaultValue: "Push \(RefName.branch(branch))", bundle: .module), info: LocalizedStringResource("push.setUpstream.info", defaultValue: "The branch goes to the chosen remote and becomes its upstream there (git push -u).", bundle: .module), confirm: LocalizedStringResource("push.setUpstream.confirm", defaultValue: "Push Branch", bundle: .module))
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
            do {
                try await repository.push(variant)
                await viewModel.refresh(note: variant.commandLine)
            } catch {
                await viewModel.refresh(note: nil)
                if let gitError = error as? GitError, await handle(gitError) { return }
                prompter.report(error, title: failure)
            }
        }
    }
}
