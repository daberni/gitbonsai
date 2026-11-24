import AppKit
import GitEngine

/// Opens repositories into tabs: from the launch, the saved session, a folder panel or the empty tab.
extension MainWindowController {
    // MARK: Opening

    /// Opens the launch arguments, or else the tabs of the last session, or else an empty tab; `folders` opened from Finder at launch join the session and the last one becomes active.
    func openInitialTabs(arguments: [String], folders: [String] = []) {
        let paths = (arguments.isEmpty ? store.openTabs : arguments) + folders
        let active = folders.isEmpty ? (arguments.isEmpty ? store.activeTab : 0) : paths.count - 1
        Task {
            let failed = await open(paths, activate: active)
            // harness: the harness drives this from outside through Accessibility and real events.
            if tabs.isEmpty || ScreenshotHarness.wantsNewTab { newTab() }
            if ScreenshotHarness.wantsClone { cloneRepository() }
            if let welcome = tabs.active?.welcome { ScreenshotHarness.clickCloneIfAsked(on: welcome) }
            // The window appears once, with all tabs, their final names and the saved tab active.
            showWindow(nil)
            // The capture renders the views itself, so the window can stay behind everything else.
            // harness: the harness launches the app hidden; window order stays the app's own.
            if ScreenshotHarness.runsInBackground { window?.orderBack(nil) }
            reportNotARepository(failed.filter { arguments.contains($0) || folders.contains($0) })
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
        let opened = locations.compactMap { $0 }.map { showRepository(at: $0) }
        if !opened.isEmpty { activate(opened[min(max(index, 0), opened.count - 1)]) }
        return zip(paths, locations).filter { $0.1 == nil }.map(\.0)
    }

    /// Adds the repository as a tab behind the others and keeps the active tab, so the empty tab can open several repositories in a row.
    func openInBackground(_ path: String) {
        Task {
            guard let location = await opener.locations(containing: [path]).first ?? nil else { return reportNotARepository([path]) }
            _ = showRepository(at: location, replacingEmptyTab: false)
            refreshTabBar()
            tabs.active?.welcome?.openPaths = tabs.repositoryPaths
            tabs.active?.welcome?.recents = store.recentRepositories
        }
    }

    private func reportNotARepository(_ paths: [String]) {
        guard let window else { return }
        for path in paths { opener.reportNotARepository(path, on: window) }
    }

    /// Returns the index of the tab that shows the repository.
    private func showRepository(at location: RepositoryLocation, replacingEmptyTab: Bool = true) -> Int {
        store.noteOpened(location.root)
        if let existing = tabs.index(showing: location.root) { return existing }
        let tab = makeTab(for: location)
        return replacingEmptyTab ? tabs.add(tab) : tabs.append(tab)
    }

    private func makeTab(for location: RepositoryLocation) -> WindowTab {
        let model = GraphViewModel(location: location, settings: context.settings)
        let controller = RepositoryViewController(context: RepositoryContext(app: context, model: model, commandBar: commandBar))
        controller.panelWidths = panelWidths
        let tab = WindowTab(repository: controller)
        controller.onLoaded = { [weak self, weak tab] in
            tab?.isLoaded = true
            self?.captureIfRequested()
        }
        controller.onSwitchWorktree = { [weak self, weak tab] path in
            guard let self, let tab, let index = tabs.index(of: tab) else { return }
            showWorktree(at: path, inTab: index)
        }
        controller.onWorktreeReplaced = { [weak self] in self?.refreshTabBar() }
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

    func chooseFolder() {
        guard let window else { return }
        opener.chooseFolders(for: window) { [weak self] paths in self?.open(paths: paths, activate: paths.count - 1) }
    }
}
