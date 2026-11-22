import AppKit
import GitEngine

/// The toolbar of a repository tab in three parts: fetch status on the left, the actions centred in the window, search on the right.
final class RepositoryToolbar: BarView {
    var onFetch: (() -> Void)?
    /// Each action button is enabled once its handler is set.
    var onBranch: (() -> Void)? { didSet { branch.isEnabled = onBranch != nil } }
    var onStash: (() -> Void)? { didSet { stash.isEnabled = onStash != nil } }
    var onPop: (() -> Void)? { didSet { pop.isEnabled = onPop != nil } }
    /// Choices for the fetch button's menu, for example other fetch variants; nil keeps a plain button.
    var fetchMenu: (() -> NSMenu)? { didSet { fetchButton.toolTip = fetchMenu == nil ? nil : "Fetch-Varianten" } }
    /// The menus of Pull and Push; the buttons are enabled by `showUpstream`.
    var pullMenu: (() -> NSMenu)?
    var pushMenu: (() -> NSMenu)?

    private lazy var fetchButton = button("Fetch", "arrow.down.to.line", #selector(fetch(_:)))
    private lazy var pull = button("Pull", "arrow.down", #selector(runPull(_:)))
    private lazy var push = button("Push", "arrow.up", #selector(runPush(_:)))
    private lazy var branch = button("Branch", "arrow.triangle.branch", #selector(runBranch(_:)))
    private lazy var stash = button("Stash", "tray.and.arrow.down", #selector(runStash(_:)))
    private lazy var pop = button("Pop", "tray.and.arrow.up", #selector(runPop(_:)))

    /// Commits to pull and to push as badges on their buttons; the push badge also warns of a missing upstream.
    private let behindBadge = CornerBadge()
    private let aheadBadge = CornerBadge()
    private let fetchLabel = NSTextField(labelWithString: "")
    let searchField = CommitSearchField()

    init() {
        super.init(edge: .bottom)
        fetchLabel.font = Theme.caption
        fetchLabel.textColor = Theme.inkMuted
        fetchLabel.translatesAutoresizingMaskIntoConstraints = false

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

        for view in [fetchLabel, actions, searchField, behindBadge, aheadBadge] { addSubview(view) }
        for (badge, button) in [(behindBadge, pull), (aheadBadge, push)] {
            NSLayoutConstraint.activate([
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: Theme.Badge.overhang),
                badge.topAnchor.constraint(equalTo: button.topAnchor, constant: -Theme.Badge.overhang),
            ])
        }
        NSLayoutConstraint.activate([
            fetchLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Window.toolbarInset),
            fetchLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.centerXAnchor.constraint(equalTo: centerXAnchor),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Space.m),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: Theme.Window.searchWidth),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Every button but Fetch starts disabled: Pull and Push come alive through `showUpstream`, the others when their handler is set.
    private func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.isEnabled = action == #selector(fetch(_:))
        return button
    }

    @objc private func runPull(_ sender: Any?) { popUp(pullMenu?(), below: sender) }
    @objc private func runPush(_ sender: Any?) { popUp(pushMenu?(), below: sender) }
    @objc func runBranch(_ sender: Any?) { onBranch?() }
    @objc private func runStash(_ sender: Any?) { onStash?() }
    @objc private func runPop(_ sender: Any?) { onPop?() }

    /// Enables Pull and Push and badges them with the commits each would move; without counts (no upstream, or never fetched) the badges stay hidden.
    /// `lacksUpstream` marks a branch that could be pushed but has no upstream yet.
    func showUpstream(canPull: Bool, canPush: Bool, upstream: Upstream?, lacksUpstream: Bool) {
        pull.isEnabled = canPull
        push.isEnabled = canPush
        behindBadge.show(upstream?.behind.map(CornerBadge.Content.count))
        pull.toolTip = upstream.flatMap { up in up.behind.map { Self.commits($0, "hinter", up.name) } }
        if lacksUpstream {
            aheadBadge.show(.symbol("exclamationmark"), tone: .danger)
            push.toolTip = "Kein Upstream: Der erste Push legt den Branch auf dem Remote an und setzt ihn als Upstream."
        } else {
            aheadBadge.show(upstream?.ahead.map(CornerBadge.Content.count))
            push.toolTip = upstream.flatMap { up in up.ahead.map { Self.commits($0, "vor", up.name) } }
        }
    }

    private static func commits(_ count: Int, _ relation: String, _ upstream: String) -> String {
        count == 0 ? "Auf dem Stand von \(upstream)" : "\(count) Commit\(count == 1 ? "" : "s") \(relation) \(upstream)"
    }

    /// The badges as shown, for harness output: "↓1 ↑2", with "-" for a hidden badge and "!" for the missing upstream.
    var upstreamCounts: String {
        let behind = behindBadge.isHidden ? "-" : "↓" + behindBadge.text
        let ahead = aheadBadge.isHidden ? "-" : aheadBadge.text.isEmpty ? "!" : "↑" + aheadBadge.text
        return "\(behind) \(ahead)"
    }

    /// Frames of the action buttons in the toolbar and the badges' tooltips, for harness output that checks badges never move a button.
    var actionLayout: String {
        let buttons = [fetchButton, pull, push, branch, stash, pop].map { "\($0.title) \(NSStringFromRect(convert($0.bounds, from: $0)))" }
        let tips = [pull, push].map { "\($0.title): \($0.toolTip ?? "-")" }
        return (buttons + tips).joined(separator: "\n")
    }

    func showFetchState(hasRemote: Bool, lastFetch: Date?) {
        let remote = hasRemote ? "origin" : "kein Remote"
        guard let lastFetch else {
            fetchLabel.stringValue = "\(remote) · noch nicht gefetcht"
            fetchLabel.toolTip = nil
            return
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        fetchLabel.stringValue = "\(remote) · gefetcht \(formatter.localizedString(for: lastFetch, relativeTo: Date()))"
        fetchLabel.toolTip = "Letzter Fetch: " + GraphRowView.exactFormatter.string(from: lastFetch)
    }

    /// With a fetch menu the button opens it below itself; otherwise it fetches right away.
    @objc private func fetch(_ sender: Any?) {
        guard let menu = fetchMenu?() else {
            onFetch?()
            return
        }
        popUp(menu, below: sender)
    }

    private func popUp(_ menu: NSMenu?, below sender: Any?) {
        guard let menu, let button = sender as? NSButton else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + Theme.Space.xs), in: button)
    }
}
