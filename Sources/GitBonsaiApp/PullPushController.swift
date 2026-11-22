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

    func refresh() {
        generation += 1
        let current = generation
        let repository = viewModel.repository
        let branch = viewModel.currentBranch
        Task {
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

    /// With an upstream: the three modes, the default marked and first, then autostash with the default mode. Without one: setting it.
    func pullMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        guard let branch, let upstream else {
            menu.addItem(header("„\(branch ?? "HEAD")“ hat keinen Upstream"))
            let set = ActionMenuItem("Upstream setzen und pullen …") { [weak self] in self?.setUpstreamAndPull() }
            set.isEnabled = branch != nil && !remoteBranches().isEmpty
            menu.addItem(set)
            return menu
        }
        menu.addItem(header("Pull von \(upstream.name) in „\(branch)“"))
        let modes = [defaultMode] + PullMode.allCases.filter { $0 != defaultMode }
        for mode in modes {
            menu.addItem(pullItem(Self.title(of: mode) + (mode == defaultMode ? " (Standard)" : ""), PullVariant(mode: mode)))
        }
        menu.addItem(.separator())
        menu.addItem(pullItem("\(Self.title(of: defaultMode)) mit Autostash", PullVariant(mode: defaultMode, autostash: true)))
        return menu
    }

    /// Pushing the branch to its upstream, or the first push that sets one; then the tags for each remote.
    func pushMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let branch, let upstream {
            let variant = PushVariant.branch(branch, remote: upstream.remote, remoteBranch: upstream.branch, setUpstream: false, forceWithLease: false)
            let item = ActionMenuItem("„\(branch)“ nach \(upstream.name) pushen") { [weak self] in self?.push(variant, upstream: upstream.name) }
            item.toolTip = variant.commandLine
            menu.addItem(item)
        } else {
            let item = ActionMenuItem("„\(branch ?? "HEAD")“ pushen und Upstream setzen …") { [weak self] in self?.firstPush() }
            item.isEnabled = branch != nil
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for remote in remotes {
            let variant = PushVariant.tags(remote: remote)
            let item = ActionMenuItem("Tags nach „\(remote)“ pushen") { [weak self] in self?.pushTags(variant) }
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

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func pullItem(_ title: String, _ variant: PullVariant) -> NSMenuItem {
        let item = ActionMenuItem(title) { [weak self] in self?.pull(variant) }
        item.toolTip = variant.commandLine
        return item
    }

    // MARK: Pull

    func pull(_ variant: PullVariant) {
        let repository = viewModel.repository
        let upstreamName = upstream?.name ?? "Upstream"
        Task {
            do {
                try await repository.pull(variant)
                await viewModel.refresh(note: variant.commandLine)
            } catch let error as GitError where error.isDivergedPull {
                await viewModel.refresh(note: nil)
                await offerRebase(after: error, upstream: upstreamName)
            } catch {
                await viewModel.refresh(note: nil)
                let stopped = (error as? GitError)?.stoppedOnConflict == true
                await prompter.report(error, title: stopped ? "Pull mit Konflikten angehalten" : "Pull fehlgeschlagen", unlessStoppedIn: repository)
            }
        }
    }

    /// A fast-forward-only pull found commits on both sides; the local ones can go on top of the upstream instead.
    /// The pull fetched first, so the counts are read again rather than taken from before it.
    private func offerRebase(after error: GitError, upstream: String) async {
        let fresh: Upstream? = if let branch { await viewModel.repository.upstream(of: branch) } else { nil }
        let alert = NSAlert()
        alert.messageText = "Branches sind auseinandergelaufen"
        let counts = fresh.flatMap { up in up.ahead.flatMap { ahead in up.behind.map { "Lokal \(ahead), auf \(upstream) \($0) neue Commits. " } } } ?? ""
        alert.informativeText = counts + "Ein Fast-Forward ist nicht möglich. Die lokalen Commits per Rebase auf \(upstream) setzen? Merge bietet das Pull-Menü."
        alert.addButton(withTitle: "Mit Rebase pullen")
        alert.addButton(withTitle: "Abbrechen")
        guard await prompter.confirm(alert) else { return }
        pull(PullVariant(mode: .rebase))
    }

    /// Asks for a remote branch, makes it the upstream and pulls with the default mode.
    private func setUpstreamAndPull() {
        guard let branch else { return }
        let candidates = remoteBranches()
        let preferred = candidates.first { $0 == "origin/\(branch)" } ?? candidates.first { $0.hasSuffix("/\(branch)") } ?? candidates.first ?? ""
        let form = ActionForm(title: "Upstream für „\(branch)“ setzen", info: "„\(branch)“ hat keinen Upstream. Der gewählte Remote-Branch wird zum Upstream, danach wird von ihm gepullt.", confirm: "Setzen und pullen")
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

    private func remoteBranches() -> [String] {
        viewModel.refs.filter { if case .remoteBranch = $0.kind { !$0.name.hasSuffix("/HEAD") } else { false } }.map(\.name).sorted()
    }

    // MARK: Push

    /// A rejection because the remote has other commits offers `--force-with-lease`, which still refuses when the remote moved since the last fetch.
    func push(_ variant: PushVariant, upstream: String) {
        run(variant, failure: "Push fehlgeschlagen") { [weak self] error in
            guard let self, error.isRejectedNonFastForward, case .branch(let branch, let remote, let remoteBranch, let setUpstream, false) = variant else { return false }
            let alert = NSAlert()
            alert.messageText = "Push abgelehnt"
            alert.informativeText = "\(upstream) enthält Commits, die in „\(branch)“ fehlen. Mit --force-with-lease überschreiben? Git bricht trotzdem ab, wenn sich \(upstream) seit dem letzten Fetch bewegt hat. Wer die fremden Commits behalten will, pullt zuerst."
            alert.addButton(withTitle: "Mit --force-with-lease überschreiben")
            alert.addButton(withTitle: "Abbrechen")
            alert.buttons.first?.hasDestructiveAction = true
            if await prompter.confirm(alert) {
                run(.branch(branch, remote: remote, remoteBranch: remoteBranch, setUpstream: setUpstream, forceWithLease: true), failure: "Force-Push fehlgeschlagen") { [weak self] error in
                    guard error.isStaleLease else { return false }
                    self?.prompter.report(error, title: "Force-Push abgelehnt: \(upstream) hat sich seit dem letzten Fetch bewegt")
                    return true
                }
            }
            return true
        }
    }

    /// The sheet of the first push: the remote (origin when there is one) and the branch's name there; the push sets the upstream.
    private func firstPush() {
        guard let branch, !remotes.isEmpty else { return }
        let form = ActionForm(title: "„\(branch)“ pushen", info: "Der Branch kommt auf das gewählte Remote und wird dort zum Upstream (git push -u).", confirm: "Pushen")
        form.addChoice(key: "remote", label: "Remote", options: remotes.map { ($0, $0) }, selected: remotes.contains("origin") ? "origin" : remotes[0])
        form.addField(key: "name", label: "Branch auf dem Remote", value: branch)
        Task {
            guard let values = await prompter.ask(form), let remote = values.text["remote"], let name = values.value("name") else { return }
            push(.branch(branch, remote: remote, remoteBranch: name, setUpstream: true, forceWithLease: false), upstream: "\(remote)/\(name)")
        }
    }

    private func pushTags(_ variant: PushVariant) {
        run(variant, failure: "Tags nicht gepusht") { _ in false }
    }

    /// Runs a push and refreshes the tab. `handle` may take over a failure and returns true when it did; otherwise git's message is shown.
    private func run(_ variant: PushVariant, failure: String, handle: @escaping (GitError) async -> Bool) {
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
