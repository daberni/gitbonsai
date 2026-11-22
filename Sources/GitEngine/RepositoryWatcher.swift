import CoreServices
import Foundation

/// Watches one working tree and its git directories with FSEvents and reports changes the `WatchScope` counts, once per burst.
///
/// A burst ends after `quiet` without relevant events, and at the latest `longest` after its first event, so a long build cannot hold changes back.
/// Bursts that fall entirely into the app's own writes on this working tree (`WriteActivity`) are dropped: the action that wrote refreshes by itself.
public final class RepositoryWatcher: @unchecked Sendable {
    public struct Burst: Sendable {
        public let events: Int
        public let firstPath: String
    }

    public let scope: WatchScope
    private let quiet: TimeInterval
    private let longest: TimeInterval
    private let ownWriteSettle: TimeInterval
    private let onChange: @Sendable (Burst) -> Void
    /// Confines the stream, the burst and the timer.
    private let queue = DispatchQueue(label: "app.gitbonsai.watcher")
    private var stream: FSEventStreamRef?
    private var burstStart: Date?
    private var burstLast = Date.distantPast
    private var burstEvents = 0
    private var burstFirstPath = ""
    private var timer: DispatchSourceTimer?

    public init(scope: WatchScope, quiet: TimeInterval = 0.2, longest: TimeInterval = 1.0, ownWriteSettle: TimeInterval = 0.5, onChange: @escaping @Sendable (Burst) -> Void) {
        self.scope = scope
        self.quiet = quiet
        self.longest = longest
        self.ownWriteSettle = ownWriteSettle
        self.onChange = onChange
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        timer?.cancel()
    }

    /// Starts the stream; events from before this moment are not reported.
    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(nil, Self.callback, &context, scope.watchedPaths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    /// Stops the stream; no change is reported afterwards.
    public func stop() {
        queue.sync {
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            stream = nil
            timer?.cancel()
            timer = nil
            burstStart = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        var relevant: [String] = []
        for index in 0..<count where index < list.count {
            if flags[index] & rescan != 0 || watcher.scope.isRelevant(list[index]) { relevant.append(list[index]) }
        }
        watcher.received(relevant)
    }

    /// Runs on `queue`.
    private func received(_ paths: [String]) {
        guard stream != nil, let first = paths.first else { return }
        let now = Date()
        if burstStart == nil {
            burstStart = now
            burstFirstPath = first
            burstEvents = 0
        }
        burstEvents += paths.count
        burstLast = now
        schedule()
    }

    private func schedule() {
        guard let start = burstStart else { return }
        let due = min(burstLast.addingTimeInterval(quiet), start.addingTimeInterval(longest))
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, due.timeIntervalSinceNow))
        timer.setEventHandler { [weak self] in self?.fire() }
        timer.resume()
        self.timer = timer
    }

    private func fire() {
        guard let start = burstStart else { return }
        let burst = Burst(events: burstEvents, firstPath: burstFirstPath)
        burstStart = nil
        timer = nil
        if WriteActivity.covers(scope.root, from: start, to: burstLast, settle: ownWriteSettle) { return }
        onChange(burst)
    }
}
