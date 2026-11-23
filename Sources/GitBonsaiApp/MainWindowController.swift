import AppKit
import GitEngine

/// The one app window: the tab row in the title bar, and below it the content of the active tab.
/// It coordinates the tab list, the repository opener and the title bar row, and answers the window's menu actions.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    let opener = RepositoryOpener()
    private let cloner = CloneController()
    private let content = TabContentView()
    private let root: FillView
    private let titlebar: TitlebarTabRow
    var tabs = TabList()
    private var frameKeeper: WindowFrameKeeper!
    /// One set of panel widths for all tabs of the window.
    let panelWidths: PanelWidths
    private var didCapture = false
    /// True once the launch arguments or the saved session have been opened; the harness waits for it.
    var didFinishInitialOpen = false

    private var tabBar: TabBarView { titlebar.tabBar }

    init(store: SessionStore) {
        self.store = store
        ScreenshotHarness.prepareLayout(store)
        let saved = store.panelWidths
        panelWidths = saved.map { PanelWidths(sidebar: $0.sidebar, detail: $0.detail) } ?? PanelWidths()
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
        let root = FillView(color: Theme.surface0)
        self.root = root
        titlebar = TitlebarTabRow(window: window, root: root)
        super.init(window: window)
        window.delegate = self
        frameKeeper = WindowFrameKeeper(window: window, store: store)
        frameKeeper.restore()
        panelWidths.onChange = { [weak self] in
            guard let self else { return }
            store.savePanelWidths(sidebar: panelWidths.sidebar, detail: panelWidths.detail)
        }
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
        tabBar.onNew = { [weak self] in self?.newTab() }
        tabBar.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        content.onDropFolders = { [weak self] paths in self?.open(paths: paths, activate: paths.count - 1) }
        // A clone below a repository folder belongs in the suggestions at once, not only after the next scan.
        cloner.onCloned = { [weak self] path in
            self?.open(paths: [path], activate: 0)
            RepositoryDiscoveryStore.shared.refresh()
        }
        cloner.onClose = { [weak self] in self?.captureIfRequested() }
    }

    // MARK: Tabs

    func activate(_ index: Int) {
        guard let tab = tabs.activate(index) else { return }
        if let welcome = tab.welcome {
            welcome.recents = store.recentRepositories
            welcome.openPaths = tabs.repositoryPaths
            welcome.refresh()
        }
        content.show(tab.view)
        tab.repository?.becameVisible()
        if let responder = tab.repository?.preferredFirstResponder ?? tab.welcome?.searchField { window?.makeFirstResponder(responder) }
        refreshTabBar()
        captureIfRequested()
    }

    private func moveTab(from: Int, to: Int) {
        guard tabs.move(from: from, to: to) else { return }
        refreshTabBar()
    }

    private func close(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].repository?.closed()
        guard let next = tabs.remove(at: index) else {
            newTab()
            return
        }
        activate(next)
    }

    func refreshTabBar() {
        tabBar.items = tabs.barItems
        tabBar.activeIndex = tabs.activeIndex
        if let active = tabs.active { window?.title = active.title }
        let session = tabs.session
        store.saveTabs(session.paths, active: session.active)
    }

    // MARK: Menu actions

    func newTab() {
        if let existing = tabs.welcomeIndex {
            activate(existing)
            return
        }
        let welcome = WelcomeView()
        welcome.onOpenPath = { [weak self] path, background in
            if background { self?.openInBackground(path) } else { self?.open(paths: [path], activate: 0) }
        }
        welcome.onChooseFolder = { [weak self] in self?.chooseFolder() }
        welcome.onClone = { [weak self] in self?.cloneRepository() }
        welcome.onOpenSettings = { SettingsWindowController.shared.show(.general) }
        let tab = WindowTab(welcome: welcome)
        ScreenshotHarness.waitForDiscovery(tab) { [weak self] in self?.captureIfRequested() }
        activate(tabs.append(tab))
    }

    func openRepository() {
        chooseFolder()
    }

    func cloneRepository() {
        guard let window else { return }
        cloner.show(on: window)
        ScreenshotHarness.driveClone(cloner)
    }

    func closeTab() {
        // The last empty tab has nothing left to close but the window.
        if tabs.count == 1, tabs[0].welcome != nil {
            window?.performClose(nil)
            return
        }
        close(tabs.activeIndex)
    }

    func selectNextTab() {
        activate((tabs.activeIndex + 1) % tabs.count)
    }

    func selectPreviousTab() {
        activate((tabs.activeIndex + tabs.count - 1) % tabs.count)
    }

    var recentRepositories: [String] { store.recentRepositories }

    // MARK: Command bar

    /// The tab titles in order with the active index, and the active repository tab, for the commands in `MainWindowController+Commands`.
    var commandTabs: (titles: [String], active: Int) { (tabs.barItems.map(\.title), tabs.activeIndex) }
    var activeRepository: RepositoryViewController? { tabs.active?.repository }
    func showTab(at index: Int) { activate(index) }

    // MARK: Window

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        titlebar.placeBesideTrafficLights()
        frameKeeper.windowShown()
    }

    func windowDidMove(_ notification: Notification) {
        frameKeeper.frameChanged()
    }

    func windowDidResize(_ notification: Notification) {
        frameKeeper.frameChanged()
    }

    func windowWillClose(_ notification: Notification) {
        frameKeeper.save()
        tabs.tabs.forEach { $0.repository?.closed() }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        frameKeeper.fullScreenTransitionBegan()
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        frameKeeper.fullScreenTransitionBegan()
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        frameKeeper.fullScreenTransitionEnded()
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        frameKeeper.fullScreenTransitionEnded()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        titlebar.followFullScreen()
        frameKeeper.fullScreenTransitionEnded()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        titlebar.followFullScreen()
        frameKeeper.fullScreenTransitionEnded()
    }

    // MARK: Screenshot harness

    func captureIfRequested() {
        guard !didCapture, didFinishInitialOpen, let window, ScreenshotHarness.outputPath != nil, tabs.active?.isLoaded == true, !ScreenshotHarness.holdsCapture(for: cloner) else { return }
        guard ScreenshotHarness.driveTabRow(tabBar, in: window, tabs: { [unowned self] in tabs }) else { return }
        didCapture = true
        if ScreenshotHarness.driveCommandBar(in: window, host: self) { return }
        if let welcome = tabs.active?.welcome { ScreenshotHarness.driveWelcome(welcome, in: window) }
        if let repository = tabs.active?.repository { ScreenshotHarness.driveLayout(repository.split, in: window) }
        ScreenshotHarness.captureAndQuit(window: window)
    }
}
