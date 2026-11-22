import AppKit
import GitEngine

/// The repositories found in the folders of `AppSettings.repositoryFolders`. The last result comes from a cache on disk at once; scans run in the background and replace it.
@MainActor
final class RepositoryDiscoveryStore {
    /// Posted after a scan changed the result.
    static let didChange = Notification.Name("RepositoryDiscoveryStore.didChange")
    static let shared = RepositoryDiscoveryStore()

    /// One scanned folder and what lies in it.
    struct Folder: Codable, Equatable {
        let path: String
        let repositories: [DiscoveredRepository]
    }

    private(set) var folders: [Folder] = []
    /// True once a scan of the current folders finished, so the result no longer only comes from the cache.
    private(set) var hasScanned = false
    private var scan: Task<Void, Never>?
    private var scanAgain = false
    private var scannedFolders: [String] = []
    private var scanWaiters: [@MainActor () -> Void] = []

    private init() {
        folders = loadCache().filter { AppSettings.repositoryFolders.contains($0.path) }
        NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, AppSettings.repositoryFolders != self.scannedFolders else { return }
                self.refresh()
            }
        }
    }

    /// Scans every configured folder off the main thread. A request while a scan runs starts one more scan afterwards.
    func refresh() {
        guard scan == nil else {
            scanAgain = true
            return
        }
        let paths = AppSettings.repositoryFolders
        scannedFolders = paths
        let depth = RepositoryDiscovery.defaultDepth
        scan = Task { [weak self] in
            let started = ContinuousClock.now
            let result = await Task.detached(priority: .utility) {
                await withTaskGroup(of: (Int, Folder).self) { group in
                    for (index, path) in paths.enumerated() {
                        group.addTask { (index, Folder(path: path, repositories: RepositoryDiscovery.scan(path, depth: depth))) }
                    }
                    var folders: [(Int, Folder)] = []
                    for await folder in group { folders.append(folder) }
                    return folders.sorted { $0.0 < $1.0 }.map(\.1)
                }
            }.value
            self?.finish(result, after: ContinuousClock.now - started)
        }
    }

    /// Runs `action` once the running or next scan finished.
    func whenScanned(_ action: @escaping @MainActor () -> Void) {
        scanWaiters.append(action)
    }

    private func finish(_ result: [Folder], after duration: Duration) {
        scan = nil
        let changed = result != folders || !hasScanned
        folders = result
        hasScanned = true
        ScreenshotHarness.traceDiscovery(result, duration: duration)
        if changed {
            saveCache()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
        let waiters = scanWaiters
        scanWaiters = []
        waiters.forEach { $0() }
        if scanAgain {
            scanAgain = false
            refresh()
        }
    }

    // MARK: Cache

    /// Harness runs keep their own cache, like their own defaults, so they never show or replace the user's.
    private var cacheURL: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let name = ScreenshotHarness.isActive ? "repositories-harness.json" : "repositories.json"
        return caches.appendingPathComponent("app.gitbonsai", isDirectory: true).appendingPathComponent(name)
    }

    private func loadCache() -> [Folder] {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([Folder].self, from: data)) ?? []
    }

    private func saveCache() {
        guard let cacheURL, let data = try? JSONEncoder().encode(folders) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
