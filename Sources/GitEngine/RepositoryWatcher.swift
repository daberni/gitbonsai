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
    private let queueKey = DispatchSpecificKey<Void>()
    private var stream: StreamHandle?
    private var burstStart: Date?
    private var burstLast = Date.distantPast
    private var burstEvents = 0
    private var burstFirstPath = ""
    /// Every event of the burst was the index, which the app's own reads may rewrite.
    private var burstOnlyIndex = true
    private var timer: DispatchSourceTimer?

    public init(scope: WatchScope, quiet: TimeInterval = 0.2, longest: TimeInterval = 1.0, ownWriteSettle: TimeInterval = 0.5, onChange: @escaping @Sendable (Burst) -> Void) {
        self.scope = scope
        self.quiet = quiet
        self.longest = longest
        self.ownWriteSettle = ownWriteSettle
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit {
        timer?.cancel()
        // Torn down on the queue, after any callback already running there; the callback only reaches the watcher through a weak reference.
        if let stream { queue.async { stream.invalidate() } }
    }

    /// Starts the stream; events from before this moment are not reported.
    public func start() {
        onQueue {
            guard stream == nil else { return }
            let box = Unmanaged.passRetained(WeakWatcher(self))
            var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(nil, Self.callback, &context, scope.watchedPaths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.05, flags) else {
                box.release()
                return
            }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = StreamHandle(stream: created, box: box)
        }
    }

    /// Stops the stream; no change is reported afterwards. Safe to call from `onChange`.
    public func stop() {
        onQueue {
            stream?.invalidate()
            stream = nil
            timer?.cancel()
            timer = nil
            burstStart = nil
        }
    }

    /// Runs `work` on the queue, inline when already there, so a call from a callback cannot deadlock.
    private func onQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() } else { queue.sync(execute: work) }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info, let watcher = Unmanaged<WeakWatcher>.fromOpaque(info).takeUnretainedValue().watcher else { return }
        let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        let rescan = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
        var relevant: [String] = []
        var onlyIndex = true
        for index in 0..<count where index < list.count {
            let mustScan = flags[index] & rescan != 0
            guard mustScan || watcher.scope.isRelevant(list[index]) else { continue }
            relevant.append(list[index])
            if mustScan || !watcher.scope.isIndex(list[index]) { onlyIndex = false }
        }
        watcher.received(relevant, onlyIndex: onlyIndex)
    }

    /// Runs on `queue`.
    private func received(_ paths: [String], onlyIndex: Bool) {
        guard stream != nil, let first = paths.first else { return }
        let now = Date()
        if burstStart == nil {
            burstStart = now
            burstFirstPath = first
            burstEvents = 0
            burstOnlyIndex = true
        }
        burstEvents += paths.count
        burstOnlyIndex = burstOnlyIndex && onlyIndex
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
        if WriteActivity.covers(scope.root, from: start, to: burstLast, settle: ownWriteSettle, indexOnly: burstOnlyIndex) { return }
        onChange(burst)
    }
}

/// What the stream's callback holds: the watcher may go away while the stream still delivers.
private final class WeakWatcher: @unchecked Sendable {
    weak var watcher: RepositoryWatcher?

    init(_ watcher: RepositoryWatcher) {
        self.watcher = watcher
    }
}

/// A running stream and the box its callback reads; invalidated on the watcher's queue only.
private struct StreamHandle: @unchecked Sendable {
    let stream: FSEventStreamRef
    let box: Unmanaged<WeakWatcher>

    /// No callback follows once this returns on the stream's queue, so the box can go.
    func invalidate() {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        box.release()
    }
}
