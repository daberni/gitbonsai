import os

/// Intervals of the app's long-running work in the unified log, subsystem `app.gitbonsai`, category Points of Interest: Instruments shows them, and the benchmarks read them from outside.
/// The names are stable: profiles and `Benchmarks` refer to them. Details that name paths or refs are private.
enum Signposts {
    static let signposter = OSSignposter(subsystem: "app.gitbonsai", category: .pointsOfInterest)

    /// Starts the interval `name`; `detail` goes into the log as private.
    static func begin(_ name: StaticString, _ detail: String = "") -> Interval {
        let id = signposter.makeSignpostID()
        return Interval(name: name, state: signposter.beginInterval(name, id: id, "\(detail, privacy: .private)"))
    }

    /// Runs `work` inside the interval `name`, on the caller's actor.
    static func measure<T>(_ name: StaticString, _ detail: String = "", isolation: isolated (any Actor)? = #isolation, _ work: () async throws -> T) async rethrows -> T {
        let interval = begin(name, detail)
        defer { interval.end() }
        return try await work()
    }

    struct Interval: @unchecked Sendable {
        let name: StaticString
        let state: OSSignpostIntervalState

        /// Ends the interval; `outcome` is public, such as "finished" or "failed".
        func end(_ outcome: String = "") {
            Signposts.signposter.endInterval(name, state, "\(outcome, privacy: .public)")
        }
    }
}
