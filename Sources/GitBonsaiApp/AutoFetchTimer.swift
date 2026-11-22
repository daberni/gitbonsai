import Foundation

/// Fetches one repository tab at the interval set in the settings, and follows changes of that setting at once.
/// Harness runs never fetch on their own unless `GITBONSAI_AUTO_FETCH` asks for it.
@MainActor
final class AutoFetchTimer {
    private let fetch: () async -> Void
    private var timer: Timer?
    private var isFetching = false
    private var observer: NSObjectProtocol?

    init(fetch: @escaping () async -> Void) {
        self.fetch = fetch
        observer = NotificationCenter.default.addObserver(forName: AppSettings.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        schedule()
    }

    isolated deinit {
        timer?.invalidate()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private var interval: TimeInterval? {
        if ScreenshotHarness.isActive { return ScreenshotHarness.autoFetchSeconds }
        let minutes = AppSettings.autoFetchMinutes
        return minutes > 0 ? TimeInterval(minutes * 60) : nil
    }

    private func schedule() {
        guard interval != timer?.timeInterval else { return }
        timer?.invalidate()
        timer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = interval / 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// A slow fetch is not started a second time while it still runs.
    private func fire() {
        guard !isFetching else { return }
        isFetching = true
        ScreenshotHarness.traceAutoFetch()
        Task {
            await fetch()
            isFetching = false
        }
    }
}
