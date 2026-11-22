import AppKit

/// One tab of the window: a repository or, until one is chosen, the welcome view.
@MainActor
final class WindowTab {
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

/// The tabs of the window in their order and which one is active.
@MainActor
struct TabList {
    private(set) var tabs: [WindowTab] = []
    private(set) var activeIndex = 0

    var count: Int { tabs.count }
    var isEmpty: Bool { tabs.isEmpty }
    var indices: Range<Int> { tabs.indices }
    var active: WindowTab? { tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil }

    subscript(index: Int) -> WindowTab { tabs[index] }

    func index(of tab: WindowTab) -> Int? {
        tabs.firstIndex { $0 === tab }
    }

    func index(showing repositoryPath: String) -> Int? {
        tabs.firstIndex { $0.repository?.repositoryPath == repositoryPath }
    }

    var repositoryPaths: Set<String> { Set(tabs.compactMap { $0.repository?.repositoryPath }) }

    var welcomeIndex: Int? { tabs.firstIndex { $0.welcome != nil } }

    /// Makes the tab at `index` the active one and returns it.
    mutating func activate(_ index: Int) -> WindowTab? {
        guard tabs.indices.contains(index) else { return nil }
        activeIndex = index
        return tabs[index]
    }

    mutating func append(_ tab: WindowTab) -> Int {
        tabs.append(tab)
        return tabs.count - 1
    }

    /// An empty active tab is reused, like a new tab in a browser.
    mutating func add(_ tab: WindowTab) -> Int {
        if active?.welcome != nil {
            tabs[activeIndex] = tab
            return activeIndex
        }
        return append(tab)
    }

    /// Swaps the two tabs; the active tab stays active at its new place.
    mutating func move(from: Int, to: Int) -> Bool {
        guard tabs.indices.contains(from), tabs.indices.contains(to) else { return false }
        tabs.swapAt(from, to)
        if activeIndex == from { activeIndex = to } else if activeIndex == to { activeIndex = from }
        return true
    }

    /// Removes the tab and returns the index of the tab to activate next, or nil when no tab is left.
    mutating func remove(at index: Int) -> Int? {
        tabs.remove(at: index)
        guard !tabs.isEmpty else { return nil }
        return index < activeIndex ? activeIndex - 1 : min(activeIndex, tabs.count - 1)
    }

    var barItems: [TabBarView.Item] {
        tabs.map { tab in
            TabBarView.Item(title: tab.title, toolTip: tab.repository.map { ($0.repositoryPath as NSString).abbreviatingWithTildeInPath })
        }
    }

    /// The repositories to restore next launch and the active one among them; welcome tabs are not saved.
    var session: (paths: [String], active: Int) {
        let repositoryIndices = tabs.indices.filter { tabs[$0].repository != nil }
        let paths = repositoryIndices.compactMap { tabs[$0].repository?.repositoryPath }
        return (paths, repositoryIndices.firstIndex(of: activeIndex) ?? 0)
    }
}
