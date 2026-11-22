import Foundation

/// Decides when a repository fetches on its own: once when it comes into view after a while, and periodically while it stays in view.
///
/// The rules, in the order they apply:
/// - A fetch counts from the later of the last fetch (`FETCH_HEAD`, so manual fetches count too) and the last automatic attempt, so failures do not retry on every tab switch.
/// - Coming into view fetches when that is older than `activationThreshold`.
/// - The periodic fetch doubles its interval on battery and pauses in Low Power Mode, which the user turned on to save energy; coming into view still fetches then.
/// - Failures double the periodic interval, up to eight times. A failure that looks like no network pauses the periodic fetch until the next time the tab comes into view.
public struct AutoFetchPolicy: Sendable {
    public enum Trigger: String, Sendable {
        /// The app became active or the tab became the visible one.
        case activation
        /// The periodic timer fired while the tab was visible in the active app.
        case interval
    }

    public enum Power: Sendable {
        case adapter, battery, lowPower
    }

    public enum Skip: String, Equatable, Sendable {
        case disabled, recent, lowPower, offline, backingOff, noRemote, operationInProgress, fetchRunning
    }

    /// What has to be read from the repository before a fetch may start.
    public struct Situation: Sendable {
        public var hasRemote: Bool
        public var operationInProgress: Bool
        public var fetchRunning: Bool

        public init(hasRemote: Bool, operationInProgress: Bool, fetchRunning: Bool) {
            self.hasRemote = hasRemote
            self.operationInProgress = operationInProgress
            self.fetchRunning = fetchRunning
        }
    }

    public static let activationThreshold: TimeInterval = 5 * 60
    public static let defaultIntervalMinutes = 10
    /// Minutes the periodic fetch can be set to; 0 is off.
    public static let intervalChoices = [0, 5, 10, 30]
    static let maxBackoffFactor = 8.0

    /// Someone who never chose an interval gets the default; an explicit choice, "off" included, stays.
    public static func intervalMinutes(stored: Int?) -> Int {
        stored ?? defaultIntervalMinutes
    }

    public var fetchOnActivation: Bool
    /// Seconds between periodic fetches; nil turns them off.
    public var interval: TimeInterval?
    public var activationThreshold: TimeInterval
    public private(set) var lastAttempt: Date?
    public private(set) var failures = 0
    public private(set) var isOffline = false

    public init(fetchOnActivation: Bool, interval: TimeInterval?, activationThreshold: TimeInterval = Self.activationThreshold) {
        self.fetchOnActivation = fetchOnActivation
        self.interval = interval
        self.activationThreshold = activationThreshold
    }

    /// Whether a trigger at `now` may fetch, judged without asking git; nil means it is due.
    public func skip(_ trigger: Trigger, now: Date, lastFetch: Date?, power: Power) -> Skip? {
        let latest = [lastFetch, lastAttempt].compactMap(\.self).max()
        func isRecent(within span: TimeInterval) -> Bool { latest.map { now.timeIntervalSince($0) < span } ?? false }
        switch trigger {
        case .activation:
            guard fetchOnActivation else { return .disabled }
            return isRecent(within: activationThreshold) ? .recent : nil
        case .interval:
            guard let interval, interval > 0 else { return .disabled }
            if power == .lowPower { return .lowPower }
            if isOffline { return .offline }
            let span = power == .battery ? interval * 2 : interval
            if failures > 0, let lastAttempt, now.timeIntervalSince(lastAttempt) < span * backoffFactor { return .backingOff }
            return isRecent(within: span) ? .recent : nil
        }
    }

    /// The checks that need the repository; nil means the fetch may start.
    public static func skip(_ situation: Situation) -> Skip? {
        if situation.fetchRunning { return .fetchRunning }
        if !situation.hasRemote { return .noRemote }
        if situation.operationInProgress { return .operationInProgress }
        return nil
    }

    public mutating func started(at date: Date) {
        lastAttempt = date
    }

    /// Records the outcome: nil for success, otherwise git's error output.
    public mutating func finished(failure: String?) {
        guard let failure else {
            failures = 0
            isOffline = false
            return
        }
        failures += 1
        isOffline = Self.isNetworkFailure(failure)
    }

    private var backoffFactor: Double {
        min(pow(2, Double(failures)), Self.maxBackoffFactor)
    }

    /// Git's messages when the host cannot be reached at all, as opposed to a refused login or a missing repository.
    public static func isNetworkFailure(_ stderr: String) -> Bool {
        let markers = ["could not resolve host", "could not resolve hostname", "network is unreachable", "no route to host", "connection timed out", "operation timed out", "connection refused", "failed to connect", "temporary failure in name resolution"]
        let text = stderr.lowercased()
        return markers.contains { text.contains($0) }
    }
}
