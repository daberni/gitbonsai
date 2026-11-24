import Foundation

/// Block observers that end with their owner. NotificationCenter keeps a block observer, and what it captures, until it is removed, so each one goes when this object does.
final class NotificationObservers {
    private var tokens: [NSObjectProtocol] = []

    /// `handler` runs on the main thread for every `name` posted by `object`, or by anyone when nil.
    func observe(_ name: Notification.Name, object: Any? = nil, _ handler: @escaping @Sendable @MainActor () -> Void) {
        tokens.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { _ in MainActor.assumeIsolated { handler() } })
    }

    /// Stops every observation made so far.
    func removeAll() {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
        tokens = []
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
