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
    private let root = FillView(color: Theme.surface0)
    private var tabs: [Tab] = []
    private var activeIndex = 0
    private var didCapture = false
    private var didDragTab = false
    /// True once the launch arguments or the saved session have been opened; the harness waits for it.
    private var didFinishInitialOpen = false

    init(store: SessionStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Theme.surface0
        window.tabbingMode = .disallowed
        // An empty compact toolbar makes the title bar exactly as tall as the tab row, so macOS itself centres the traffic lights on it.
        window.toolbar = NSToolbar(identifier: "GitBonsaiTitlebar")
        window.toolbarStyle = .unifiedCompact
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 900, height: 520)
        window.center()
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
        mountTabBar()
        tabBar.onSelect = { [weak self] index in self?.activate(index) }
        tabBar.onClose = { [weak self] index in self?.close(index) }
        tabBar.onNew = { [weak self] in self?.newTab(nil) }
        tabBar.onMove = { [weak self] from, to in self?.moveTab(from: from, to: to) }
        content.onDropFolders = { [weak self] paths in self?.open(paths: paths, activate: paths.count - 1) }
    }

    /// macOS decides which parts of the title bar move the window from the views inside the title bar only.
    /// So the tab row lives there, behind the traffic lights, and tells it that clicks on it are its own; the free space moves the window through the tab row.
    /// In full screen the title bar slides away, so the row moves into the window content.
    private func mountTabBar() {
        guard let window else { return }
        tabBar.removeFromSuperview()
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        let titlebar = window.standardWindowButton(.closeButton)?.superview
        let host: NSView = window.styleMask.contains(.fullScreen) ? root : titlebar ?? root
        host.addSubview(tabBar, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: host.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: TabBarView.height),
        ])
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

    private func moveTab(from: Int, to: Int) {
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return }
        tabs.swapAt(from, to)
        if activeIndex == from { activeIndex = to } else if activeIndex == to { activeIndex = from }
        refreshTabBar()
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

    /// The tabs start right of the traffic lights. The buttons are left where macOS puts them; in full screen they are gone.
    private func placeTabsBesideTrafficLights() {
        guard let window else { return }
        guard !window.styleMask.contains(.fullScreen), let zoom = window.standardWindowButton(.zoomButton), let container = zoom.superview else {
            tabBar.leadingInset = 12
            return
        }
        let frame = container.convert(zoom.frame, to: tabBar)
        tabBar.leadingInset = frame.maxX + 14
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        placeTabsBesideTrafficLights()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        mountTabBar()
        placeTabsBesideTrafficLights()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        mountTabBar()
        placeTabsBesideTrafficLights()
    }

    // MARK: Screenshot harness

    private func captureIfRequested() {
        guard !didCapture, didFinishInitialOpen, let window, ScreenshotHarness.outputPath != nil, tabs.indices.contains(activeIndex), tabs[activeIndex].isLoaded else { return }
        let environment = ProcessInfo.processInfo.environment
        // A real click through the window proves that the tab row receives events under the title bar.
        if let target = environment["GITBONSAI_CLICK_TAB"].flatMap(Int.init), target != activeIndex, let frame = tabBar.frameOfTab(target) {
            ScreenshotHarness.click(in: window, at: tabBar.convert(CGPoint(x: frame.midX - 10, y: frame.midY), to: nil))
            if activeIndex != target { FileHandle.standardError.write(Data("click on tab \(target) did not reach the tab row\n".utf8)) }
            guard tabs[activeIndex].isLoaded else { return }
        }
        // `from:to` drags the tab at `from` onto the place of the tab at `to`. Selecting it calls back in here, so the flag keeps the drag from starting twice.
        if !didDragTab, let spec = environment["GITBONSAI_DRAG_TAB"] {
            let parts = spec.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, let source = tabBar.frameOfTab(parts[0]), let target = tabBar.frameOfTab(parts[1]) {
                didDragTab = true
                let start = tabBar.convert(CGPoint(x: source.midX, y: source.midY), to: nil)
                let end = tabBar.convert(CGPoint(x: target.midX + (parts[1] > parts[0] ? 8 : -8), y: target.midY), to: nil)
                ScreenshotHarness.drag(in: window, from: start, to: end, steps: 12)
                FileHandle.standardError.write(Data("tab order after drag: \(tabs.map(\.title).joined(separator: ", ")), active \(tabs[activeIndex].title)\n".utf8))
            }
        }
        didCapture = true
        ScreenshotHarness.captureAndQuit(window: window)
    }
}
