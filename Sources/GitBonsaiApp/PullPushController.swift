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
            menu.addItem(header(branch.map { name -> RefString in "\(branch: name) hat keinen Upstream" } ?? "HEAD hat keinen Upstream"))
            let set = ActionMenuItem("Upstream setzen und pullen …") { [weak self] in self?.setUpstreamAndPull() }
            set.isEnabled = branch != nil && !remoteBranches().isEmpty
            menu.addItem(set)
            return menu
        }
        menu.addItem(header("Pull von \(remoteBranch: upstream.name) in \(branch: branch)"))
        let modes = [defaultMode] + PullMode.allCases.filter { $0 != defaultMode }
        for mode in modes {
            menu.addItem(pullItem(RefString(Self.title(of: mode) + (mode == defaultMode ? " (Standard)" : "")), PullVariant(mode: mode)))
        }
        return menu
    }

    /// Pushing the branch to its upstream, or the first push that sets one; then the tags for each remote.
    func pushMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let branch, let upstream {
            let variant = PushVariant.branch(branch, remote: upstream.remote, remoteBranch: upstream.branch, setUpstream: false, forceWithLease: false)
            let item = ActionMenuItem("\(branch: branch) nach \(remoteBranch: upstream.name) pushen") { [weak self] in self?.push(variant, upstream: upstream.name) }
            item.toolTip = variant.commandLine
            menu.addItem(item)
        } else {
            let item = ActionMenuItem(branch.map { name -> RefString in "\(branch: name) pushen und Upstream setzen …" } ?? "HEAD pushen und Upstream setzen …") { [weak self] in self?.firstPush() }
            item.isEnabled = branch != nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for remote in remotes {
            let variant = PushVariant.tags(remote: remote)
            let item = ActionMenuItem("Tags nach \(remote: remote) pushen") { [weak self] in self?.pushTags(variant) }
            item.toolTip = variant.commandLine
            menu.addItem(item)
        }
        return menu
    }

    private static func title(of mode: PullMode) -> String {
        switch mode {
        case .fastForwardOnly: "Nur Fast-Forward"
        case .merge: "Merge"
        case .rebase: "Rebase"
        }
    }

    private func header(_ title: RefString) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.setTitle(title)
        item.isEnabled = false
        return item
    }

    private func pullItem(_ title: RefString, _ variant: PullVariant) -> NSMenuItem {
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
        let upstreamName = upstream?.name ?? "Upstream"
        do {
            let result = try await repository.pull(variant)
            await viewModel.refresh(note: variant.commandLine + (result.localChangesConflicted ? " · " + Self.conflictedChanges : ""))
            if result.localChangesConflicted { prompter.onToast?(RefString("Pull fertig, " + Self.conflictedChanges), prompter.onShowConflicts.map { show in ToastAction(title: "Konflikte anzeigen") { show() } }) }
            return true
        } catch let error as GitError where error.isDivergedPull {
            await viewModel.refresh(note: nil)
            await offerRebase(after: error, upstream: upstreamName)
        } catch {
            await viewModel.refresh(note: nil)
            let stopped = (error as? GitError)?.stoppedOnConflict == true
            await prompter.report(error, title: stopped ? "Pull mit Konflikten angehalten" : "Pull fehlgeschlagen", unlessStoppedIn: repository)
        }
        return false
    }

    /// The status line after a pull whose carried changes conflicted on the way back.
    static let conflictedChanges = "lokale Änderungen mit Konflikten zurückgeholt, Stash „autostash“ bleibt erhalten"

    /// A fast-forward-only pull found commits on both sides; the local ones can go on top of the upstream, or the two can be merged.
    /// The pull fetched first, so the counts are read again rather than taken from before it.
    private func offerRebase(after error: GitError, upstream: String) async {
        let fresh: Upstream? = if let branch { await viewModel.repository.upstream(of: branch) } else { nil }
        let counts: RefString = fresh.flatMap { up in up.ahead.flatMap { ahead in up.behind.map { behind -> RefString in "Lokal \(ahead), auf \(remoteBranch: upstream) \(behind) neue Commits: " } } } ?? ""
        let summary: RefString = "\(counts)Ein Fast-Forward ist nicht möglich. Rebase setzt die lokalen Commits auf \(remoteBranch: upstream), Merge führt beide Seiten mit einem Merge-Commit zusammen."
        prompter.showSheet(title: "Branches sind auseinandergelaufen", summary: summary, details: GitFailureText.details(of: error), actions: [
            FailureAction(title: "Mit Rebase pullen") { [weak self] in self?.pull(PullVariant(mode: .rebase)) },
            FailureAction(title: "Mit Merge pullen") { [weak self] in self?.pull(PullVariant(mode: .merge)) },
        ])
    }

    /// Asks for a remote branch, makes it the upstream and pulls with the default mode.
    func setUpstreamAndPull() {
        guard let branch else { return }
        let candidates = remoteBranches()
        let preferred = candidates.first { $0 == "origin/\(branch)" } ?? candidates.first { $0.hasSuffix("/\(branch)") } ?? candidates.first ?? ""
        let form = ActionForm(title: "Upstream für \(branch: branch) setzen", info: "\(branch: branch) hat keinen Upstream. Der gewählte Remote-Branch wird zum Upstream, danach wird von ihm gepullt.", confirm: "Setzen und pullen")
        form.addComboField(key: "upstream", label: "Upstream", value: preferred, suggestions: candidates)
        Task {
            guard let values = await prompter.ask(form), let upstream = values.value("upstream") else { return }
            do {
                try await viewModel.repository.setUpstream(of: branch, to: upstream)
            } catch {
                prompter.report(error, title: "Upstream nicht gesetzt")
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
        run(variant, failure: "Push fehlgeschlagen") { [weak self] error in
            guard let self, error.isRejectedNonFastForward, case .branch(let branch, let remote, let remoteBranch, let setUpstream, false) = variant else { return false }
            let force = PushVariant.branch(branch, remote: remote, remoteBranch: remoteBranch, setUpstream: setUpstream, forceWithLease: true)
            let canPullFirst = branch == self.branch && self.upstream?.name == upstream
            var actions: [FailureAction] = []
            if canPullFirst {
                actions.append(FailureAction(title: "Pullen und erneut pushen") { [weak self] in
                    guard let self else { return }
                    Task {
                        guard await self.performPull(PullVariant(mode: self.defaultMode)) else { return }
                        self.push(variant, upstream: upstream)
                    }
                })
            }
            actions.append(FailureAction(title: "Mit --force-with-lease überschreiben", isDestructive: true) { [weak self] in self?.forcePush(force, upstream: upstream) })
            prompter.report(error, title: "Push abgelehnt", summary: "\(remoteBranch: upstream) enthält Commits, die in \(branch: branch) fehlen. Pullen holt sie zuerst; --force-with-lease überschreibt sie, solange sich \(remoteBranch: upstream) seit dem letzten Fetch nicht bewegt hat.", actions: actions)
            return true
        }
    }

    private func forcePush(_ variant: PushVariant, upstream: String) {
        run(variant, failure: "Force-Push fehlgeschlagen") { [weak self] error in
            guard error.isStaleLease else { return false }
            self?.prompter.report(error, title: "Force-Push abgelehnt", summary: "\(remoteBranch: upstream) hat sich seit dem letzten Fetch bewegt. Erst fetchen und prüfen, was dort neu ist.")
            return true
        }
    }

    /// The sheet of the first push: the remote (origin when there is one) and the branch's name there; the push sets the upstream.
    func firstPush() {
        guard let branch, !remotes.isEmpty else { return }
        let form = ActionForm(title: "\(branch: branch) pushen", info: "Der Branch kommt auf das gewählte Remote und wird dort zum Upstream (git push -u).", confirm: "Pushen")
        form.addChoice(key: "remote", label: "Remote", options: remotes.map { ($0, $0) }, selected: remotes.contains("origin") ? "origin" : remotes[0])
        form.addField(key: "name", label: "Branch auf dem Remote", value: branch)
        Task {
            guard let values = await prompter.ask(form), let remote = values.text["remote"], let name = values.value("name") else { return }
            push(.branch(branch, remote: remote, remoteBranch: name, setUpstream: true, forceWithLease: false), upstream: "\(remote)/\(name)")
        }
    }

    func pushTags(_ variant: PushVariant) {
        run(variant, failure: "Tags nicht gepusht") { _ in false }
    }

    /// Runs a push and refreshes the tab. `handle` may take over a failure and returns true when it did; otherwise git's message is shown.
    private func run(_ variant: PushVariant, failure: RefString, handle: @escaping (GitError) async -> Bool) {
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
