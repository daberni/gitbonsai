import AppKit
import GitEngine
import IOKit.ps

/// Fetches one repository tab on its own, following `AutoFetchPolicy`: when the app becomes active or the tab becomes visible, and periodically while both hold.
/// It fetches quietly; the status line and the toolbar's fetch state show the outcome.
@MainActor
final class AutoFetchScheduler {
    private let fetch: () async -> Error?
    private let lastFetch: () -> Date?
    private let situation: () async -> AutoFetchPolicy.Situation
    private let isVisible: () -> Bool
    private let settings: AppSettings
    private let trace: TraceSink
    private var policy: AutoFetchPolicy
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var isLoaded = false
    private var isChecking = false

    /// `fetch` runs the fetch and returns git's error; `situation` reads what decides whether the repository can fetch now.
    init(fetch: @escaping () async -> Error?, lastFetch: @escaping () -> Date?, situation: @escaping () async -> AutoFetchPolicy.Situation, isVisible: @escaping () -> Bool, settings: AppSettings, trace: TraceSink) {
        self.trace = trace
        self.settings = settings
        self.fetch = fetch
        self.lastFetch = lastFetch
        self.situation = situation
        self.isVisible = isVisible
        policy = AutoFetchPolicy(fetchOnActivation: false, interval: nil)
        applySettings()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.consider(.activation) }
        })
    }

    isolated deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }


    /// The first load finished; a fetch before it would race the load for the refs.
    func loaded() {
        isLoaded = true
        consider(.activation)
    }

    /// The tab closed: no timer, no observers, no fetch.
    func stop() {
        isLoaded = false
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// The tab became the visible one in its window.
    func becameVisible() {
        consider(.activation)
    }

    private func applySettings() {
        policy.fetchOnActivation = settings.fetchOnActivation
        let minutes = settings.autoFetchMinutes
        policy.interval = minutes > 0 ? TimeInterval(minutes * 60) : nil
        scheduleTimer()
    }

    /// The timer only asks the policy, which knows the real interval with power and backoff applied, so it ticks more often than any interval.
    private func scheduleTimer() {
        let tick = policy.interval.map { min($0, 60) }
        guard tick != timer?.timeInterval else { return }
        timer?.invalidate()
        timer = nil
        guard let tick else { return }
        let timer = Timer(timeInterval: tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.consider(.interval) }
        }
        timer.tolerance = tick / 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func trace(_ trigger: AutoFetchPolicy.Trigger, skip: AutoFetchPolicy.Skip?) {
        trace.note("autoFetch", "\(trigger.rawValue): \(skip.map { "skip \($0.rawValue)" } ?? "fetch with \(GitRunner.defaultGitPath())")")
    }

    private func consider(_ trigger: AutoFetchPolicy.Trigger) {
        guard isLoaded, !isChecking, isVisible(), appIsActive else { return }
        if let skip = policy.skip(trigger, now: Date(), lastFetch: lastFetch(), power: Self.power) {
            // Periodic ticks that are not due are the normal case and stay out of the trace.
            if trigger == .activation || skip != .recent { trace(trigger, skip: skip) }
            return
        }
        isChecking = true
        Task {
            defer { isChecking = false }
            if let skip = AutoFetchPolicy.skip(await situation()) {
                trace(trigger, skip: skip)
                return
            }
            trace(trigger, skip: nil)
            policy.started(at: Date())
            let error = await fetch()
            policy.finished(failure: error.map { ($0 as? GitError)?.stderr ?? "\($0)" })
        }
    }

    private var appIsActive: Bool { NSApp.isActive }

    private static var power: AutoFetchPolicy.Power {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let source = IOPSGetProvidingPowerSourceType(info).takeUnretainedValue() as String
        return source == kIOPMBatteryPowerKey ? .battery : .adapter
    }
}

