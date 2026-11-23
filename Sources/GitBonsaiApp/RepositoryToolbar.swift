import AppKit
import GitEngine

/// The toolbar of a repository tab in three parts: fetch status on the left, the actions centred in the window, search on the right.
final class RepositoryToolbar: BarView {
    /// Runs when the Fetch button has no menu of variants.
    var onFetch: (() -> Void)?
    /// Each action button is enabled once its handler is set.
    var onBranch: (() -> Void)? { didSet { branch.isEnabled = onBranch != nil } }
    var onPop: (() -> Void)? { didSet { pop.isEnabled = onPop != nil } }
    /// The variants in the fetch button's menu, the first enabled one its default; without them the button only runs `onFetch`.
    var fetchMenu: (() -> NSMenu)? { didSet { applyRemoteState() } }
    /// Cancels the running fetch, pull or push; the running button offers it.
    var onCancelRemote: (() -> Void)?
    /// The menus of Pull and Push, the first enabled entry each button's default; the buttons start disabled until `showUpstream` enables them.
    var pullMenu: (() -> NSMenu)?
    var pushMenu: (() -> NSMenu)?
    /// The Stash menu, its first entry stashing everything at once; the button is enabled while it is set.
    var stashMenu: (() -> NSMenu)? { didSet { stash.isEnabled = stashMenu != nil } }

    private lazy var fetchButton = MenuButton(LocalizedStringResource("toolbar.fetch.title", defaultValue: "Fetch", bundle: .module, comment: "Toolbar button."), "arrow.down.to.line", enabled: true) { [weak self] in self?.fetchMenu?() ?? self?.singleFetchMenu() ?? NSMenu() }
    private lazy var pull = MenuButton(LocalizedStringResource("toolbar.pull.title", defaultValue: "Pull", bundle: .module, comment: "Toolbar button."), "arrow.down", enabled: false) { [weak self] in self?.pullMenu?() ?? NSMenu() }
    private lazy var push = MenuButton(LocalizedStringResource("toolbar.push.title", defaultValue: "Push", bundle: .module, comment: "Toolbar button."), "arrow.up", enabled: false) { [weak self] in self?.pushMenu?() ?? NSMenu() }
    private lazy var branch = button(LocalizedStringResource("toolbar.branch.title", defaultValue: "Branch", bundle: .module, comment: "Toolbar button that creates a branch."), "arrow.triangle.branch", #selector(runBranch(_:)))
    private lazy var stash = MenuButton(LocalizedStringResource("toolbar.stash.title", defaultValue: "Stash", bundle: .module, comment: "Toolbar button, the verb."), "tray.and.arrow.down", enabled: false) { [weak self] in self?.stashMenu?() ?? NSMenu() }
    private lazy var pop = button(LocalizedStringResource("toolbar.pop.title", defaultValue: "Pop", bundle: .module, comment: "Toolbar button that pops the latest stash."), "tray.and.arrow.up", #selector(runPop(_:)))

    /// Commits to pull and to push as badges on their buttons; the push badge also warns of a missing upstream.
    private let behindBadge = CornerBadge()
    private let aheadBadge = CornerBadge()
    private let fetchLabel = NSTextField(labelWithString: "")
    /// Turns beside the fetch state while a fetch runs.
    private let fetchSpinner = NSProgressIndicator()
    private var showsSpinner = false
    /// What `showUpstream` last set, combined with the running operation in `applyRemoteState`.
    private var canPull = false
    private var canPush = false
    private var pullToolTip: String?
    private var pushToolTip: String?
    private var activity: RemoteActivity.Running?
    let searchField = CommitSearchField()

    init() {
        super.init(edge: .bottom)
        fetchLabel.font = Theme.caption
        fetchLabel.textColor = Theme.inkMuted
        fetchLabel.translatesAutoresizingMaskIntoConstraints = false
        fetchSpinner.style = .spinning
        fetchSpinner.controlSize = .mini
        fetchSpinner.isDisplayedWhenStopped = false
        fetchSpinner.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [
            fetchButton,
            pull,
            push,
            branch,
            stash,
            pop,
        ])
        actions.orientation = .horizontal
        actions.spacing = Theme.Space.s
        actions.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        for (button, kind) in [(fetchButton, RemoteActivity.Kind.fetch), (pull, .pull), (push, .push)] {
            button.runningMenu = { [weak self] in self?.cancelMenu(kind) ?? NSMenu() }
        }

        for view in [fetchLabel, fetchSpinner, actions, searchField, behindBadge, aheadBadge] { addSubview(view) }
        for (badge, button) in [(behindBadge, pull), (aheadBadge, push)] {
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: Theme.Badge.overhang),
                badge.topAnchor.constraint(equalTo: button.topAnchor, constant: -Theme.Badge.overhang),
            ])
        }
        NSLayoutConstraint.activate([
            fetchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Window.toolbarInset),
            fetchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            fetchSpinner.leadingAnchor.constraint(equalTo: fetchLabel.trailingAnchor, constant: Theme.Space.xs),
            fetchSpinner.centerYAnchor.constraint(equalTo: fetchLabel.centerYAnchor),
            actions.centerXAnchor.constraint(equalTo: centerXAnchor),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: Theme.Window.searchWidth),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Buttons that run directly start disabled and come alive when their handler is set.
    private func button(_ title: LocalizedStringResource, _ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title.text, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.isEnabled = false
        return button
    }

    @objc func runBranch(_ sender: Any?) { onBranch?() }
    @objc private func runPop(_ sender: Any?) { onPop?() }

    /// Enables Pull and Push and badges them with the commits each would move; without counts (no upstream, or never fetched) the badges stay hidden.
    /// `lacksUpstream` marks a branch that could be pushed but has no upstream yet.
    func showUpstream(canPull: Bool, canPush: Bool, upstream: Upstream?, lacksUpstream: Bool) {
        self.canPull = canPull
        self.canPush = canPush
        behindBadge.show(upstream?.behind.map(CornerBadge.Content.count))
        pullToolTip = upstream.flatMap { up in up.behind.map { Self.behind($0, up.name) } }
        if lacksUpstream {
            aheadBadge.show(.symbol("exclamationmark"), tone: .danger)
            pushToolTip = String(localized: "toolbar.push.noUpstreamToolTip", defaultValue: "No upstream: the first push creates the branch on the remote and sets it as upstream.", bundle: .module)
        } else {
            aheadBadge.show(upstream?.ahead.map(CornerBadge.Content.count))
            pushToolTip = upstream.flatMap { up in up.ahead.map { Self.ahead($0, up.name) } }
        }
        applyRemoteState()
    }

    /// Shows the running fetch, pull or push on its button; a background one, such as the automatic fetch, shows only in the fetch state, so the buttons do not flicker.
    func showRemoteActivity(_ running: RemoteActivity.Running?) {
        activity = running?.isBackground == true ? nil : running
        applyRemoteState()
    }

    /// While an operation runs its button spins and offers Cancel, and the other remote buttons wait with a tooltip naming it.
    private func applyRemoteState() {
        let fetchToolTip = fetchMenu == nil ? nil : String(localized: "toolbar.fetch.toolTip", defaultValue: "Fetch all remotes; more options behind the arrow", bundle: .module)
        let states: [(MenuButton, RemoteActivity.Kind, Bool, String?)] = [
            (fetchButton, .fetch, true, fetchToolTip),
            (pull, .pull, canPull, pullToolTip),
            (push, .push, canPush, pushToolTip),
        ]
        for (button, kind, available, toolTip) in states {
            guard let activity else {
                button.isRunning = false
                button.isEnabled = available
                button.toolTip = toolTip
                continue
            }
            button.isRunning = activity.kind == kind
            button.isEnabled = activity.kind == kind
            button.toolTip = Self.runningToolTip(activity.kind)
        }
    }

    private static func runningToolTip(_ kind: RemoteActivity.Kind) -> String {
        switch kind {
        case .fetch: String(localized: "toolbar.remote.fetchRunning", defaultValue: "Fetch is running", bundle: .module, comment: "Tooltip of the toolbar's remote buttons while a fetch runs.")
        case .pull: String(localized: "toolbar.remote.pullRunning", defaultValue: "Pull is running", bundle: .module, comment: "Tooltip of the toolbar's remote buttons while a pull runs.")
        case .push: String(localized: "toolbar.remote.pushRunning", defaultValue: "Push is running", bundle: .module, comment: "Tooltip of the toolbar's remote buttons while a push runs.")
        }
    }

    private func cancelMenu(_ kind: RemoteActivity.Kind) -> NSMenu {
        let title = switch kind {
        case .fetch: LocalizedStringResource("toolbar.fetch.cancel", defaultValue: "Cancel Fetch", bundle: .module, comment: "Menu item of the running Fetch button.")
        case .pull: LocalizedStringResource("toolbar.pull.cancel", defaultValue: "Cancel Pull", bundle: .module, comment: "Menu item of the running Pull button.")
        case .push: LocalizedStringResource("toolbar.push.cancel", defaultValue: "Cancel Push", bundle: .module, comment: "Menu item of the running Push button.")
        }
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(title) { [weak self] in self?.onCancelRemote?() })
        return menu
    }

    /// The remote buttons as shown, for harness output: enabled, running and tooltip of each.
    var remoteButtonsText: String {
        [fetchButton, pull, push].map { "\($0.title): \($0.isEnabled ? "enabled" : "disabled")\($0.isRunning ? " [running]" : "") · tooltip \($0.toolTip ?? "-")" }.joined(separator: "\n")
    }

    private static func behind(_ count: Int, _ upstream: String) -> String {
        count == 0 ? upToDate(upstream) : String(localized: "toolbar.pull.behind", defaultValue: "\(count) commits behind \(upstream)", bundle: .module)
    }

    private static func ahead(_ count: Int, _ upstream: String) -> String {
        count == 0 ? upToDate(upstream) : String(localized: "toolbar.push.ahead", defaultValue: "\(count) commits ahead of \(upstream)", bundle: .module)
    }

    private static func upToDate(_ upstream: String) -> String {
        String(localized: "toolbar.sync.upToDate", defaultValue: "Up to date with \(upstream)", bundle: .module)
    }

    /// The badges as shown, for harness output: "↓1 ↑2", with "-" for a hidden badge and "!" for the missing upstream.
    var upstreamCounts: String {
        let behind = behindBadge.isHidden ? "-" : "↓" + behindBadge.text
        let ahead = aheadBadge.isHidden ? "-" : aheadBadge.text.isEmpty ? "!" : "↑" + aheadBadge.text
        return "\(behind) \(ahead)"
    }

    /// Frames of the action buttons in the toolbar, "▾" for those that open a menu, and the badges' tooltips, for harness output that checks badges and menus never move a button.
    var actionLayout: String {
        let menuButtons = [fetchButton, pull, push, stash].map { "\($0.title) ▾ \(NSStringFromRect(convert($0.bounds, from: $0)))" }
        let buttons = menuButtons + [branch, pop].map { "\($0.title) \(NSStringFromRect(convert($0.bounds, from: $0)))" }
        let tips = [pull, push].map { "\($0.title): \($0.toolTip ?? "-")" }
        return (buttons + tips).joined(separator: "\n")
    }

    /// What the fetch state names: the upstream's remote, the only remote, or all of them, which is what Fetch reaches.
    enum FetchTarget: Equatable {
        case none
        case remote(String)
        case allRemotes
    }

    /// "origin · fetched 5 minutes ago"; while a fetch runs "origin · fetching…" with the spinner, after a failed one "origin · fetch failed" with git's message as tooltip.
    func showFetchState(target: FetchTarget, lastFetch: Date?, fetching: Bool, failure: String?) {
        let remote = switch target {
        case .none: String(localized: "toolbar.fetch.noRemote", defaultValue: "no remote", bundle: .module, comment: "Start of the toolbar's fetch status, in place of the remote name.")
        case .remote(let name): name
        case .allRemotes: String(localized: "toolbar.fetch.allRemotes", defaultValue: "all remotes", bundle: .module, comment: "Start of the toolbar's fetch status when there are several remotes and the branch has no upstream.")
        }
        if fetching { fetchSpinner.startAnimation(nil) } else { fetchSpinner.stopAnimation(nil) }
        showsSpinner = fetching
        let exact = lastFetch.map { DateText.exact($0) }
        let lastFetchTip = exact.map { String(localized: "toolbar.fetch.lastFetchToolTip", defaultValue: "Last fetch: \($0)", bundle: .module) }
        let state: String
        if fetching {
            state = String(localized: "toolbar.fetch.fetching", defaultValue: "fetching…", bundle: .module, comment: "The toolbar's fetch status after the remote name while a fetch runs.")
            fetchLabel.toolTip = lastFetchTip
        } else if let failure {
            state = String(localized: "toolbar.fetch.failed", defaultValue: "fetch failed", bundle: .module, comment: "The toolbar's fetch status after the remote name when the last fetch failed.")
            fetchLabel.toolTip = ([failure] + (lastFetchTip.map { [$0] } ?? [])).joined(separator: "\n")
        } else if let lastFetch {
            let relative = DateText.relative(lastFetch)
            state = String(localized: "toolbar.fetch.fetched", defaultValue: "fetched \(relative)", bundle: .module, comment: "The toolbar's fetch status after the remote name, with a relative time such as “5 minutes ago”.")
            fetchLabel.toolTip = lastFetchTip
        } else {
            state = String(localized: "toolbar.fetch.notFetched", defaultValue: "not fetched yet", bundle: .module, comment: "The toolbar's fetch status after the remote name.")
            fetchLabel.toolTip = nil
        }
        fetchLabel.stringValue = "\(remote) · \(state)"
    }

    /// The fetch state as shown, for harness output.
    var fetchStateText: String { "\(fetchLabel.stringValue)\(showsSpinner ? " [spinner]" : "") · tooltip \(fetchLabel.toolTip ?? "-")" }

    private func singleFetchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(LocalizedStringResource("toolbar.fetch.title", defaultValue: "Fetch", bundle: .module, comment: "Menu item that fetches the only remote.")) { [weak self] in self?.onFetch?() })
        return menu
    }
}
