/// Folds refresh triggers that arrive together into one run: the app's activation, a tab switch and the window becoming key come within a few milliseconds of each other.
///
/// A trigger while a run is only scheduled joins it. A trigger after the run started reading may have missed what caused it, so exactly one more run follows.
public struct RefreshCoalescer: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case idle
        case scheduled
        case running(rerun: Bool)
    }

    public private(set) var state: State = .idle

    public init() {}

    /// Returns true when the caller has to schedule a run.
    public mutating func request() -> Bool {
        switch state {
        case .idle:
            state = .scheduled
            return true
        case .scheduled:
            return false
        case .running:
            state = .running(rerun: true)
            return false
        }
    }

    /// The scheduled run starts reading the repository now.
    public mutating func begin() {
        guard state == .scheduled else { return }
        state = .running(rerun: false)
    }

    /// Returns true when a trigger arrived during the run and the caller has to schedule another one.
    public mutating func finish() -> Bool {
        guard case .running(let rerun) = state else { return false }
        state = rerun ? .scheduled : .idle
        return rerun
    }
}
