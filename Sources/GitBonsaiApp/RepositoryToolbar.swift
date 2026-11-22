import AppKit

/// The toolbar of a repository tab in three parts: fetch status on the left, the actions centred in the window, search on the right.
final class RepositoryToolbar: BarView, NSSearchFieldDelegate {
    var onFetch: (() -> Void)?
    var onSearch: ((String) -> Void)?
    /// Each action button is enabled once its handler is set.
    var onPull: (() -> Void)? { didSet { pull.isEnabled = onPull != nil } }
    var onPush: (() -> Void)? { didSet { push.isEnabled = onPush != nil } }
    var onBranch: (() -> Void)? { didSet { branch.isEnabled = onBranch != nil } }
    var onStash: (() -> Void)? { didSet { stash.isEnabled = onStash != nil } }
    var onPop: (() -> Void)? { didSet { pop.isEnabled = onPop != nil } }
    /// Choices for the fetch button's menu, for example other fetch variants; nil keeps a plain button.
    var fetchMenu: (() -> NSMenu)? { didSet { fetchButton.toolTip = fetchMenu == nil ? nil : "Fetch-Varianten" } }

    private lazy var fetchButton = button("Fetch", "arrow.down.to.line", #selector(fetch(_:)))
    private lazy var pull = button("Pull", "arrow.down", #selector(runPull(_:)))
    private lazy var push = button("Push", "arrow.up", #selector(runPush(_:)))
    private lazy var branch = button("Branch", "arrow.triangle.branch", #selector(runBranch(_:)))
    private lazy var stash = button("Stash", "tray.and.arrow.down", #selector(runStash(_:)))
    private lazy var pop = button("Pop", "tray.and.arrow.up", #selector(runPop(_:)))

    private let fetchLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()

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

        searchField.placeholderString = "Commits durchsuchen"
        searchField.controlSize = .large
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(search(_:))
        searchField.translatesAutoresizingMaskIntoConstraints = false

        for view in [fetchLabel, actions, searchField] { addSubview(view) }
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

    /// Every button but Fetch starts disabled and comes alive when its handler is set.
    private func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.isEnabled = action == #selector(fetch(_:))
        return button
    }

    @objc private func runPull(_ sender: Any?) { onPull?() }
    @objc private func runPush(_ sender: Any?) { onPush?() }
    @objc private func runBranch(_ sender: Any?) { onBranch?() }
    @objc private func runStash(_ sender: Any?) { onStash?() }
    @objc private func runPop(_ sender: Any?) { onPop?() }

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
        guard let menu = fetchMenu?(), let button = sender as? NSButton else {
            onFetch?()
            return
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + Theme.Space.xs), in: button)
    }

    @objc private func search(_ sender: NSSearchField) {
        onSearch?(sender.stringValue)
    }
}
