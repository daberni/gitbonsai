import AppKit
import GitEngine

/// Reconciles a repository tab with its repository: when it becomes the visible tab, when the app becomes active, and when its files change on disk.
/// Changes made in a terminal, an editor or another worktree show up without a click. Tabs in the background wait until they are shown, which reconciles them anyway.
///
/// The refresh is local; fetching stays with `AutoFetchScheduler`, which listens to activation on its own.
@MainActor
final class TabReconciler {
    enum Trigger: String {
        case activation, visible, files
    }

    /// Activation, the window becoming key and a tab switch arrive within a few milliseconds; this long a pause lets them meet.
    private static let gatherDelay: Duration = .milliseconds(30)
    /// How long to wait for another refresh to end before trying again.
    private static let retryDelay: Duration = .milliseconds(150)

    private let name: String
    private let refresh: () async -> GraphViewModel.Reconciliation
    private let isVisible: () -> Bool
    /// Called after every run that reconciled the tab.
    var onReconciled: (() -> Void)?
    private var coalescer = RefreshCoalescer()
    private var triggers: [Trigger] = []
    private var isLoaded = false
    private var observer: NSObjectProtocol?
    private var watcher: RepositoryWatcher?
    /// Counts the watchers started, so a scope that is read after the tab moved on is dropped.
    private var watchGeneration = 0

    init(name: String, refresh: @escaping () async -> GraphViewModel.Reconciliation, isVisible: @escaping () -> Bool) {
        self.name = name
        self.refresh = refresh
        self.isVisible = isVisible
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.request(.activation) }
        }
    }

    isolated deinit {
        observer.map(NotificationCenter.default.removeObserver)
        watcher?.stop()
    }

    /// Watches the working tree at `root` and the repository's git directories; replaces the watcher of a worktree the tab showed before.
    func watch(root: String, commonDirectory: String, gitPath: String) {
        stopWatching()
        let generation = watchGeneration
        Task { [weak self] in
            guard let scope = try? await WatchScope.of(root: root, commonDirectory: commonDirectory, gitPath: gitPath) else { return }
            guard let self, generation == watchGeneration else { return }
            let watcher = RepositoryWatcher(scope: scope) { [weak self] burst in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.filesChanged(burst) } }
            }
            watcher.start()
            self.watcher = watcher
            ScreenshotHarness.traceWatcher(name, "watching \(scope.watchedPaths.joined(separator: ", "))")
        }
    }

    /// The tab closed: the stream stops before the tab goes away.
    func stopWatching() {
        watchGeneration += 1
        guard let watcher else { return }
        watcher.stop()
        self.watcher = nil
        ScreenshotHarness.traceWatcher(name, "stopped")
    }

    /// A hidden tab only notes the change; becoming visible reconciles it.
    private func filesChanged(_ burst: RepositoryWatcher.Burst) {
        let visible = isVisible()
        ScreenshotHarness.traceWatcher(name, "\(burst.events) events from \(burst.firstPath)\(visible ? "" : ", hidden: waits until shown")")
        if visible { request(.files) }
    }

    /// The first load finished; before it there is nothing to bring up to date.
    func loaded() {
        isLoaded = true
    }

    func request(_ trigger: Trigger) {
        guard isLoaded, isVisible() else { return }
        triggers.append(trigger)
        if coalescer.request() { schedule() }
    }

    private func schedule(after delay: Duration = gatherDelay) {
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            await self?.run()
        }
    }

    private func run() async {
        coalescer.begin()
        let gathered = triggers
        triggers = []
        let start = ContinuousClock.now
        // A tab that went into the background meanwhile reconciles when it comes back.
        guard isVisible() else {
            ScreenshotHarness.traceReturnRefresh(name, triggers: gathered.map(\.rawValue), outcome: "skipped, hidden", duration: start.duration(to: .now))
            if coalescer.finish() { schedule() }
            return
        }
        let outcome = await refresh()
        ScreenshotHarness.traceReturnRefresh(name, triggers: gathered.map(\.rawValue), outcome: "\(outcome)", duration: start.duration(to: .now))
        if outcome == .done { onReconciled?() }
        let again = coalescer.finish()
        if outcome == .refreshing {
            // The other refresh may have read the repository before the change; this run is owed.
            triggers += gathered
            if !again { _ = coalescer.request() }
            schedule(after: Self.retryDelay)
        } else if again {
            schedule()
        }
    }
}
