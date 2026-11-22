import AppKit

/// The toolbar of a repository tab in three parts: fetch status on the left, the actions centred in the window, search on the right.
final class RepositoryToolbar: BarView, NSSearchFieldDelegate {
    var onFetch: (() -> Void)?
    var onSearch: ((String) -> Void)?

    private let fetchLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()

    init() {
        super.init(edge: .bottom)
        fetchLabel.font = Theme.caption
        fetchLabel.textColor = Theme.inkMuted
        fetchLabel.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [
            button("Fetch", "arrow.down.to.line", #selector(fetch(_:))),
            button("Pull", "arrow.down", nil),
            button("Push", "arrow.up", nil),
            button("Branch", "arrow.triangle.branch", nil),
            button("Stash", "tray.and.arrow.down", nil),
            button("Pop", "tray.and.arrow.up", nil),
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

    /// Actions without a selector are shown but not yet available.
    private func button(_ title: String, _ symbol: String, _ action: Selector?) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.isEnabled = action != nil
        if action == nil { button.toolTip = "Kommt mit dem MVP" }
        return button
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

    @objc private func fetch(_ sender: Any?) {
        onFetch?()
    }

    @objc private func search(_ sender: NSSearchField) {
        onSearch?(sender.stringValue)
    }
}
