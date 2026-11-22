import AppKit
import GitEngine

/// The one app window: the tab row in the title bar, and below it the content of the active tab.
/// It coordinates the tab list, the repository opener and the title bar row, and answers the window's menu actions.
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private let store: SessionStore
    private let opener = RepositoryOpener()
    private let content = TabContentView()
    private let root: FillView
    private let titlebar: TitlebarTabRow
    private var tabs = TabList()
    private var didCapture = false
    /// True once the launch arguments or the saved session have been opened; the harness waits for it.
    private var didFinishInitialOpen = false

    private var tabBar: TabBarView { titlebar.tabBar }

    init(store: SessionStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.Window.defaultSize), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.surface0
        window.tabbingMode = .disallowed
        // An empty compact toolbar makes the title bar exactly as tall as the tab row, so macOS itself centres the traffic lights on it.
        window.toolbar = NSToolbar(identifier: "GitBonsaiTitlebar")
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.minSize = Theme.Window.minimumSize
        window.center()
        let root = FillView(color: Theme.surface0)
        self.root = root
        titlebar = TitlebarTabRow(window: window, root: root)
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { nil }

    private func buildContent() {
        guard let window else { return }
        root.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: TabBarView.height),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window.contentView = root
        titlebar.mount()
        tabBar.onSelect = { [weak self] index in self?.activate(index) }
        tabBar.onClose = { [weak self] index in self?.close(index) }
        tabBar.onNew = { [weak self] in self?.newTab(nil) }
        tabBar.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        content.onDropFolders = { [weak self] paths in self?.open(paths: paths, activate: paths.count - 1) }
    }

    // MARK: Opening

    /// Opens the launch arguments, or else the tabs of the last session, or else an empty tab.
    func openInitialTabs(arguments: [String]) {
        let paths = arguments.isEmpty ? store.openTabs : arguments
        let active = arguments.isEmpty ? store.activeTab : 0
        Task {
            let failed = await open(paths, activate: active)
            if tabs.isEmpty || ScreenshotHarness.wantsNewTab { newTab(nil) }
            // The window appears once, with all tabs, their final names and the saved tab active.
            showWindow(nil)
            // The capture renders the views itself, so the window can stay behind everything else.
            if ScreenshotHarness.runsInBackground { window?.orderBack(nil) }
            if !arguments.isEmpty { reportNotARepository(failed) }
            didFinishInitialOpen = true
            captureIfRequested()
        }
    }

    func open(paths: [String], activate index: Int) {
        Task { reportNotARepository(await open(paths, activate: index)) }
    }

    /// Opens each folder as a tab, in order, and returns the folders that lie in no repository. A folder inside a repository opens that repository; one that is already open is not opened twice.
    /// All folders are resolved before the first tab is added, so the tab row changes once.
    private func open(_ paths: [String], activate index: Int) async -> [String] {
        let locations = await opener.locations(containing: paths)
        let opened = locations.compactMap { $0 }.map(showRepository(at:))
        if !opened.isEmpty { activate(opened[min(max(index, 0), opened.count - 1)]) }
        return zip(paths, locations).filter { $0.1 == nil }.map(\.0)
    }

    private func reportNotARepository(_ paths: [String]) {
        guard let window else { return }
        for path in paths { opener.reportNotARepository(path, on: window) }
    }

    /// Returns the index of the tab that shows the repository.
    private func showRepository(at location: RepositoryLocation) -> Int {
        store.noteOpened(location.root)
        if let existing = tabs.index(showing: location.root) { return existing }
        return tabs.add(makeTab(for: location))
    }

    private func makeTab(for location: RepositoryLocation) -> WindowTab {
        let controller = RepositoryViewController(location: location)
        let tab = WindowTab(repository: controller)
        controller.onLoaded = { [weak self, weak tab] in
            tab?.isLoaded = true
            self?.captureIfRequested()
        }
        controller.onSwitchWorktree = { [weak self, weak tab] path in
            guard let self, let tab, let index = tabs.index(of: tab) else { return }
            showWorktree(at: path, inTab: index)
        }
        return tab
    }

    /// The tab and everything loaded in it stay; only HEAD and the working directory change. A tab that already shows that worktree wins.
    private func showWorktree(at path: String, inTab index: Int) {
        if let existing = tabs.index(showing: path) {
            activate(existing)
            return
        }
        tabs[index].repository?.switchWorktree(to: path)
        refreshTabBar()
    }

    private func chooseFolder() {
        guard let window else { return }
        opener.chooseFolders(for: window) { [weak self] paths in self?.open(paths: paths, activate: paths.count - 1) }
    }

    // MARK: Tabs

    private func activate(_ index: Int) {
        guard let tab = tabs.activate(index) else { return }
        tab.welcome?.recents = store.recentRepositories
        content.show(tab.view)
        if let responder = tab.repository?.preferredFirstResponder { window?.makeFirstResponder(responder) }
        refreshTabBar()
        captureIfRequested()
    }

    private func moveTab(from: Int, to: Int) {
        guard tabs.move(from: from, to: to) else { return }
        refreshTabBar()
    }

    private func close(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        guard let next = tabs.remove(at: index) else {
            newTab(nil)
            return
        }
        activate(next)
    }

    private func refreshTabBar() {
        tabBar.items = tabs.barItems
        tabBar.activeIndex = tabs.activeIndex
        traceTabRow()
        if let active = tabs.active { window?.title = active.title }
        let session = tabs.session
        store.saveTabs(session.paths, active: session.active)
    }

    // MARK: Menu actions

    @objc func newTab(_ sender: Any?) {
        if let existing = tabs.welcomeIndex {
            activate(existing)
            return
        }
        let welcome = WelcomeView()
        welcome.onOpenPath = { [weak self] path in self?.open(paths: [path], activate: 0) }
        welcome.onChooseFolder = { [weak self] in self?.chooseFolder() }
        activate(tabs.append(WindowTab(welcome: welcome)))
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
        close(tabs.activeIndex)
    }

    @objc func selectNextTab(_ sender: Any?) {
        activate((tabs.activeIndex + 1) % tabs.count)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        activate((tabs.activeIndex + tabs.count - 1) % tabs.count)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectNextTab(_:)), #selector(selectPreviousTab(_:)): tabs.count > 1
        default: true
        }
    }

    var recentRepositories: [String] { store.recentRepositories }

    // MARK: Window

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        titlebar.placeBesideTrafficLights()
        traceTabRow()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        titlebar.followFullScreen()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        titlebar.followFullScreen()
    }

    // MARK: Screenshot harness

    private var tracedTabRow = ""

    private func traceTabRow() {
        let titles = tabs.barItems.enumerated().map { $0.offset == tabs.activeIndex ? "[\($0.element.title)]" : $0.element.title }
        let state = "tab row (window \(window?.isVisible == true ? "visible" : "hidden")): " + titles.joined(separator: " | ")
        guard state != tracedTabRow else { return }
        tracedTabRow = state
        ScreenshotHarness.traceStartup(state)
    }

    private func captureIfRequested() {
        guard !didCapture, didFinishInitialOpen, let window, ScreenshotHarness.outputPath != nil, tabs.active?.isLoaded == true else { return }
        guard ScreenshotHarness.driveTabRow(tabBar, in: window, tabs: { [unowned self] in tabs }) else { return }
        didCapture = true
        ScreenshotHarness.captureAndQuit(window: window)
    }
}
