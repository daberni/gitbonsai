import AppKit
import GitEngine

/// The one app window: the tab row in the title bar, and below it the content of the active tab.
/// A tab holds either a repository or, until one is chosen, the welcome view.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    @MainActor
    private final class Tab {
        let repository: RepositoryViewController?
        let welcome: WelcomeView?
        var isLoaded = false

        init(repository: RepositoryViewController) {
            self.repository = repository
            welcome = nil
        }

        init(welcome: WelcomeView) {
            repository = nil
            self.welcome = welcome
            isLoaded = true
        }

        var title: String { repository?.name ?? "Neuer Tab" }
        var view: NSView { repository?.view ?? welcome ?? NSView() }
    }

    private let store: SessionStore
    private let tabBar = TabBarView()
    private let content = TabContentView()
    private var tabs: [Tab] = []
    private var activeIndex = 0
    private var didCapture = false
    /// True once the launch arguments or the saved session have been opened; the harness waits for it.
    private var didFinishInitialOpen = false

    init(store: SessionStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.surface0
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 900, height: 520)
        window.center()
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        guard let window else { return }
        let root = FillView(color: Theme.surface0)
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        root.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: root.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
            content.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        tabBar.onSelect = { [weak self] index in self?.activate(index) }
        tabBar.onClose = { [weak self] index in self?.close(index) }
        tabBar.onNew = { [weak self] in self?.newTab(nil) }
        content.onDropFolders = { [weak self] paths in self?.open(paths: paths, activate: paths.count - 1) }
    }

    // MARK: Opening

    /// Opens the launch arguments, or else the tabs of the last session, or else an empty tab.
    func openInitialTabs(arguments: [String]) {
        let paths = arguments.isEmpty ? store.openTabs : arguments
        let active = arguments.isEmpty ? store.activeTab : 0
        Task {
            await open(paths, activate: active, reportErrors: !arguments.isEmpty)
            if tabs.isEmpty || ProcessInfo.processInfo.environment["GITBONSAI_NEW_TAB"] != nil { newTab(nil) }
            didFinishInitialOpen = true
            captureIfRequested()
        }
    }

    func open(paths: [String], activate index: Int) {
        Task { await open(paths, activate: index, reportErrors: true) }
    }

    /// Opens each folder as a tab, in order. A folder inside a repository opens that repository; one that is already open is not opened twice.
    private func open(_ paths: [String], activate index: Int, reportErrors: Bool) async {
        var opened: [Int] = []
        for path in paths {
            do {
                let root = try await Repository.root(containing: path)
                opened.append(showRepository(at: root))
            } catch {
                if reportErrors { reportNotARepository(path) }
            }
        }
        guard !opened.isEmpty else { return }
        activate(opened[min(max(index, 0), opened.count - 1)])
    }

    /// Returns the index of the tab that shows the repository. An empty active tab is reused, like a new tab in a browser.
    private func showRepository(at root: String) -> Int {
        store.noteOpened(root)
        if let existing = tabs.firstIndex(where: { $0.repository?.repositoryPath == root }) { return existing }
        let tab = makeTab(for: root)
        if tabs.indices.contains(activeIndex), tabs[activeIndex].welcome != nil {
            tabs[activeIndex] = tab
            return activeIndex
        }
        tabs.append(tab)
        return tabs.count - 1
    }

    private func makeTab(for root: String) -> Tab {
        let controller = RepositoryViewController(repositoryPath: root)
        let tab = Tab(repository: controller)
        controller.onLoaded = { [weak self, weak tab] in
            tab?.isLoaded = true
            self?.captureIfRequested()
        }
        controller.onNameChanged = { [weak self] in self?.refreshTabBar() }
        controller.onSwitchWorktree = { [weak self, weak tab] path in
            guard let self, let tab, let index = tabs.firstIndex(where: { $0 === tab }) else { return }
            showWorktree(at: path, inTab: index)
        }
        return tab
    }

    /// The tab and everything loaded in it stay; only HEAD and the working directory change. A tab that already shows that worktree wins.
    private func showWorktree(at path: String, inTab index: Int) {
        if let existing = tabs.firstIndex(where: { $0.repository?.repositoryPath == path }) {
            activate(existing)
            return
        }
        tabs[index].repository?.switchWorktree(to: path)
        refreshTabBar()
    }

    private func reportNotARepository(_ path: String) {
        guard ScreenshotHarness.outputPath == nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Kein Git-Repository"
        alert.informativeText = "\((path as NSString).abbreviatingWithTildeInPath) liegt in keinem Repository."
        alert.beginSheetModal(for: window)
    }

    private func chooseFolder() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Öffnen"
        panel.message = "Ordner eines Repositorys wählen. Ein Unterordner genügt."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let paths = panel.urls.map(\.path)
            self?.open(paths: paths, activate: paths.count - 1)
        }
    }

    // MARK: Tabs

    private func activate(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        activeIndex = index
        let tab = tabs[index]
        tab.welcome?.recents = store.recentRepositories
        content.show(tab.view)
        if let responder = tab.repository?.preferredFirstResponder { window?.makeFirstResponder(responder) }
        refreshTabBar()
        captureIfRequested()
    }

    private func close(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        if tabs.isEmpty {
            newTab(nil)
            return
        }
        activate(index < activeIndex ? activeIndex - 1 : min(activeIndex, tabs.count - 1))
    }

    private func refreshTabBar() {
        tabBar.items = tabs.map { tab in
            TabBarView.Item(title: tab.title, toolTip: tab.repository.map { ($0.repositoryPath as NSString).abbreviatingWithTildeInPath })
        }
        tabBar.activeIndex = activeIndex
        if tabs.indices.contains(activeIndex) { window?.title = tabs[activeIndex].title }
        let repositoryIndices = tabs.indices.filter { tabs[$0].repository != nil }
        store.saveTabs(repositoryIndices.compactMap { tabs[$0].repository?.repositoryPath }, active: repositoryIndices.firstIndex(of: activeIndex) ?? 0)
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) {
        if let existing = tabs.firstIndex(where: { $0.welcome != nil }) {
            activate(existing)
            return
        }
        let welcome = WelcomeView()
        welcome.onOpenPath = { [weak self] path in self?.open(paths: [path], activate: 0) }
        welcome.onChooseFolder = { [weak self] in self?.chooseFolder() }
        tabs.append(Tab(welcome: welcome))
        activate(tabs.count - 1)
    }

    @objc func openRepository(_ sender: Any?) {
        chooseFolder()
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        open(paths: [path], activate: 0)
    }

    @objc func closeTab(_ sender: Any?) {
        // The last empty tab has nothing left to close but the window.
        if tabs.count == 1, tabs[0].welcome != nil {
            window?.performClose(nil)
            return
        }
        close(activeIndex)
    }

    @objc func selectNextTab(_ sender: Any?) {
        activate((activeIndex + 1) % tabs.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        activate((activeIndex + tabs.count - 1) % tabs.count)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): tabs.count > 1
        default: true
        }
    }

    var recentRepositories: [String] { store.recentRepositories }

    // MARK: Title bar

    /// The tab row is taller than a standard title bar, so the traffic lights are moved down to sit on the tabs' centre line and the tabs start right of them.
    private func alignTitleBar() {
        guard let window else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        var trailingEdge: CGFloat = 0
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let container = button.superview else { continue }
            if !isFullScreen {
                let centreFromTop = TabBarView.height / 2 + 1
                let y = container.isFlipped ? centreFromTop - button.frame.height / 2 : container.bounds.height - centreFromTop - button.frame.height / 2
                if abs(button.frame.minY - y) > 0.5 { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
            }
            trailingEdge = max(trailingEdge, container.convert(button.frame, to: nil).maxX)
        }
        tabBar.leadingInset = isFullScreen ? 12 : trailingEdge + 14
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        alignTitleBar()
    }

    // AppKit puts the buttons back whenever it lays out the title bar, so the position is checked after every event.
    func windowDidUpdate(_ notification: Notification) { alignTitleBar() }

    // MARK: Screenshot harness

    private func captureIfRequested() {
        guard !didCapture, didFinishInitialOpen, let window, ScreenshotHarness.outputPath != nil, tabs.indices.contains(activeIndex), tabs[activeIndex].isLoaded else { return }
        // A real click through the window proves that the tab row receives events under the title bar.
        if let target = ProcessInfo.processInfo.environment["GITBONSAI_CLICK_TAB"].flatMap(Int.init), target != activeIndex, let frame = tabBar.frameOfTab(target) {
            let point = tabBar.convert(CGPoint(x: frame.midX - 10, y: frame.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { window.sendEvent(event) }
            }
            if activeIndex != target { FileHandle.standardError.write(Data("click on tab \(target) did not reach the tab row\n".utf8)) }
            guard tabs[activeIndex].isLoaded else { return }
        }
        didCapture = true
        alignTitleBar()
        ScreenshotHarness.captureAndQuit(window: window)
    }
}
