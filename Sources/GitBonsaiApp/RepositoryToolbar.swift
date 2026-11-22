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
    var fetchMenu: (() -> NSMenu)? { didSet { fetchButton.toolTip = fetchMenu == nil ? nil : "Alle Remotes fetchen, weitere Varianten über den Pfeil" } }
    /// The menus of Pull and Push, the first enabled entry each button's default; the buttons start disabled until `showUpstream` enables them.
    var pullMenu: (() -> NSMenu)?
    var pushMenu: (() -> NSMenu)?
    /// The Stash menu, its first entry stashing everything at once; the button is enabled while it is set.
    var stashMenu: (() -> NSMenu)? { didSet { stash.isEnabled = stashMenu != nil } }

    private lazy var fetchButton = MenuButton("Fetch", "arrow.down.to.line", enabled: true) { [weak self] in self?.fetchMenu?() ?? self?.singleFetchMenu() ?? NSMenu() }
    private lazy var pull = MenuButton("Pull", "arrow.down", enabled: false) { [weak self] in self?.pullMenu?() ?? NSMenu() }
    private lazy var push = MenuButton("Push", "arrow.up", enabled: false) { [weak self] in self?.pushMenu?() ?? NSMenu() }
    private lazy var branch = button("Branch", "arrow.triangle.branch", #selector(runBranch(_:)))
    private lazy var stash = MenuButton("Stash", "tray.and.arrow.down", enabled: false) { [weak self] in self?.stashMenu?() ?? NSMenu() }
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

    /// Buttons that run directly start disabled and come alive when their handler is set.
    private func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
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

    /// Frames of the action buttons in the toolbar, "▾" for those that open a menu, and the badges' tooltips, for harness output that checks badges and menus never move a button.
    var actionLayout: String {
        let menuButtons = [fetchButton, pull, push, stash].map { "\($0.title) ▾ \(NSStringFromRect(convert($0.bounds, from: $0)))" }
        let buttons = menuButtons + [branch, pop].map { "\($0.title) \(NSStringFromRect(convert($0.bounds, from: $0)))" }
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

    private func singleFetchMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ActionMenuItem("Fetch") { [weak self] in self?.onFetch?() })
        return menu
    }
}

/// A toolbar action with several variants, split in two like a macOS split button: the main part runs the default variant, the chevron behind a divider opens all variants below the button.
/// The default is the menu's first enabled entry, so the menus list it first. The chevron part adds a fixed width, so the button never changes size with the menu's contents.
final class MenuButton: NSButton, NSMenuDelegate {
    private let entries: () -> NSMenu
    private let divider = DividerLine()
    private let chevron = NSImageView()

    init(_ title: String, _ symbol: String, enabled: Bool, entries: @escaping () -> NSMenu) {
        self.entries = entries
        super.init(frame: .zero)
        cell = SplitCell()
        self.title = title
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imagePosition = .imageLeading
        bezelStyle = .rounded
        controlSize = .large
        target = self
        action = #selector(runDefault(_:))
        isEnabled = enabled

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Varianten")
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Theme.Toolbar.chevronSize, weight: .semibold)
        chevron.contentTintColor = Theme.inkMuted
        for view in [divider, chevron] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: Theme.Stroke.hairline),
            divider.heightAnchor.constraint(equalToConstant: Theme.Toolbar.dividerHeight),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Toolbar.menuPart),
            chevron.centerXAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Toolbar.menuPart / 2),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateParts()
    }

    required init?(coder: NSCoder) { nil }

    override var isEnabled: Bool { didSet { updateParts() } }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += Theme.Toolbar.menuPart
        return size
    }

    /// Disabled, divider and chevron fade like the title.
    private func updateParts() {
        let alpha = isEnabled ? 1 : Theme.Toolbar.disabledAlpha
        divider.alphaValue = alpha
        chevron.alphaValue = alpha
    }

    /// A press on the chevron part opens the variants; anywhere else the button tracks the click as usual and runs the default.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isEnabled, point.x >= bounds.maxX - Theme.Toolbar.menuPart else {
            super.mouseDown(with: event)
            return
        }
        // Built anew for every opening, since branch, upstream and remotes change between clicks. The button shows pressed while the menu is open and lets go the moment it closes:
        // `popUp` returns only after the chosen entry's action has run, so waiting for it would keep the button pressed through that action.
        let menu = entries()
        menu.delegate = self
        setPressed(true, by: "press")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + Theme.Space.xs), in: self)
        setPressed(false, by: "popUp returned")
    }

    func menuDidClose(_ menu: NSMenu) {
        setPressed(false, by: "menu closed")
    }

    /// Draws the change at once instead of with the window's next update, which waits for the menu's tracking to unwind.
    private func setPressed(_ pressed: Bool, by cause: String) {
        guard isHighlighted != pressed else { return }
        isHighlighted = pressed
        displayIfNeeded()
        if ScreenshotHarness.isActive { ScreenshotHarness.traceMenuButton(self, cause: cause) }
    }

    /// Divider and chevron are drawing only; every press belongs to the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    @objc private func runDefault(_ sender: Any?) {
        let menu = entries()
        guard let index = menu.items.firstIndex(where: { $0.isEnabled && !$0.isSeparatorItem && $0.action != nil }) else { return }
        menu.performActionForItem(at: index)
    }
}

/// Lays out image and title in the main part only, left of the chevron part.
private final class SplitCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        var main = cellFrame
        main.size.width -= Theme.Toolbar.menuPart
        super.drawInterior(withFrame: main, in: controlView)
    }
}

/// The divider between the main part and the chevron part of a split button.
private final class DividerLine: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.inkFaint.cgColor
        }
    }
}
