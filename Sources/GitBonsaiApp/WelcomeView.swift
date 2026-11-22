import AppKit

/// What a tab shows before it has a repository: a search over the recently used repositories and those found in the repository folders, and the way to open another folder.
final class WelcomeView: NSView, NSSearchFieldDelegate {
    var recents: [String] = [] { didSet { if recents != oldValue { rebuild() } } }
    /// Repositories already open in a tab; their rows are marked.
    var openPaths: Set<String> = [] { didSet { if openPaths != oldValue { rebuild() } } }
    var onOpenPath: ((_ path: String, _ background: Bool) -> Void)?
    var onChooseFolder: (() -> Void)?
    var onClone: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    let searchField = NSSearchField()
    let listView = WelcomeListView()
    private typealias M = Theme.Welcome
    private let openButton = NSButton(title: String(localized: "Open folder…", bundle: .module), target: nil, action: nil)
    let cloneButton = NSButton(title: String(localized: "Clone…", bundle: .module), target: nil, action: nil)
    private let scrollView = NSScrollView()
    private let discovery = RepositoryDiscoveryStore.shared

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        searchField.placeholderString = String(localized: "Search repositories", bundle: .module)
        searchField.controlSize = .large
        searchField.delegate = self
        openButton.bezelStyle = .rounded
        openButton.controlSize = .large
        openButton.bezelColor = Theme.moss
        openButton.target = self
        openButton.action = #selector(chooseFolder(_:))
        cloneButton.bezelStyle = .rounded
        cloneButton.controlSize = .large
        cloneButton.target = self
        cloneButton.action = #selector(clone(_:))
        scrollView.documentView = listView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        listView.onOpen = { [weak self] path, background in self?.onOpenPath?(path, background) }
        listView.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        for view in [searchField, cloneButton, openButton, scrollView] as [NSView] { addSubview(view) }
        NotificationCenter.default.addObserver(forName: RepositoryDiscoveryStore.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Shows the cached result at once and scans the folders again in the background.
    func refresh() {
        rebuild()
        discovery.refresh()
    }

    private func rebuild() {
        let configured = Set(AppSettings.repositoryFolders)
        let folders = discovery.folders.filter { configured.contains($0.path) }
        listView.showsFolderHint = configured.isEmpty
        listView.list = WelcomeList(recents: recents, folders: folders, openPaths: openPaths, filter: searchField.stringValue, recentLimit: M.maximumRows)
    }

    // MARK: Layout

    private var columnX: CGFloat { max((bounds.width - M.columnWidth) / 2, Theme.Space.xl) }
    private var columnWidth: CGFloat { min(M.columnWidth, bounds.width - 2 * Theme.Space.xl) }
    private var introTop: CGFloat { max(bounds.height * M.topShare, M.minimumTop) + Theme.Window.toolbar }
    private var searchTop: CGFloat { introTop + M.introHeight - M.searchHeight - M.searchGap }

    override func layout() {
        super.layout()
        openButton.sizeToFit()
        cloneButton.sizeToFit()
        let openWidth = openButton.frame.width
        let cloneWidth = cloneButton.frame.width
        openButton.frame = CGRect(x: columnX + columnWidth - openWidth, y: searchTop, width: openWidth, height: M.searchHeight)
        cloneButton.frame = CGRect(x: openButton.frame.minX - Theme.Space.s - cloneWidth, y: searchTop, width: cloneWidth, height: M.searchHeight)
        searchField.frame = CGRect(x: columnX, y: searchTop, width: cloneButton.frame.minX - Theme.Space.s - columnX, height: M.searchHeight)
        let listTop = searchTop + M.searchHeight + M.searchGap
        scrollView.frame = CGRect(x: columnX, y: listTop, width: columnWidth, height: max(bounds.height - listTop - Theme.Space.xl, 0))
        listView.frame = CGRect(x: 0, y: 0, width: scrollView.contentSize.width, height: listView.frame.height)
        listView.setFrameSize(NSSize(width: scrollView.contentSize.width, height: listView.frame.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        Theme.surface0.setFill()
        bounds.fill()
        // An empty toolbar band, so the active tab has something to run into and the layout does not jump between tabs.
        Theme.surface1.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: Theme.Window.toolbar).fill()
        Theme.hairline.setFill()
        CGRect(x: 0, y: Theme.Window.toolbar - Theme.Stroke.hairline, width: bounds.width, height: Theme.Stroke.hairline).fill()
        Glyph.bonsaiMain.draw(in: CGRect(x: columnX + M.textInset, y: introTop, width: M.mark, height: M.mark), color: Theme.moss, context: context)
        NSAttributedString(string: String(localized: "Open Repository", bundle: .module, comment: "Heading of the welcome page."), attributes: [.font: Theme.heading, .foregroundColor: Theme.ink]).draw(at: CGPoint(x: columnX + M.textInset, y: introTop + M.titleOffset))
    }

    // MARK: Keys

    func controlTextDidChange(_ notification: Notification) {
        rebuild()
    }

    /// The arrow keys move through the list while the search field keeps the focus; ⏎ opens the selection, Esc clears the search.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): listView.moveSelection(by: 1)
        case #selector(NSResponder.moveUp(_:)): listView.moveSelection(by: -1)
        case #selector(NSResponder.insertNewline(_:)): listView.openSelection(background: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
        case #selector(NSResponder.cancelOperation(_:)):
            searchField.stringValue = ""
            rebuild()
        default: return false
        }
        return true
    }

    /// ⌘⏎ reaches the window as a key equivalent before the search field sees it, and opens the selection in the background.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, window?.firstResponder === searchField.currentEditor() else { return super.performKeyEquivalent(with: event) }
        listView.openSelection(background: true)
        return true
    }

    @objc private func chooseFolder(_ sender: Any?) {
        onChooseFolder?()
    }

    @objc private func clone(_ sender: Any?) {
        onClone?()
    }
}

/// Hosts the active tab's content and accepts a folder dropped anywhere on it.
final class TabContentView: ContainerView {
    var onDropFolders: (([String]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { nil }

    private func folders(in sender: NSDraggingInfo) -> [String] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(\.hasDirectoryPath).map(\.path)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        folders(in: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let paths = folders(in: sender)
        guard !paths.isEmpty else { return false }
        onDropFolders?(paths)
        return true
    }
}
