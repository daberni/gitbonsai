import Darwin
import Foundation

/// Measures the app from outside: launches it isolated through `scripts/launch-dev.sh` on a repository, reads one signpost interval it emits (subsystem `app.gitbonsai`) from `log stream`, and quits it.
enum AppRun {
    /// The app bundle is built once per run, in release, before the first launch.
    nonisolated(unsafe) private static var built = false

    /// The duration of the first interval named `name` that the launched app completes; fails after `timeout`.
    static func interval(_ name: String, repository: URL, timeout: Duration = .seconds(60)) async throws -> Duration {
        if !built {
            log("Building GitBonsai Dev.app …")
            try Fixtures.run(Fixtures.packageRoot.appendingPathComponent("scripts/make-app-bundle.sh"), [])
            built = true
        }
        let stream = try SignpostStream()
        defer { stream.stop() }
        let output = try Fixtures.run(Fixtures.packageRoot.appendingPathComponent("scripts/launch-dev.sh"), ["--no-build", repository.path])
        let text = String(decoding: output, as: UTF8.self)
        guard let pid = text.split(separator: "\n").first(where: { $0.hasPrefix("pid:") }).flatMap({ Int32($0.dropFirst(4).trimmingCharacters(in: .whitespaces)) }) else { throw FixtureError("launch-dev.sh printed no pid") }
        defer { kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let duration = stream.interval(name, pid: pid) { return duration }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw FixtureError("\(name) did not end within \(timeout)")
    }
}

/// `log stream --signpost` of the app's subsystem, parsed as it arrives: begin and end events matched by process and signpost id.
private final class SignpostStream: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var buffer = Data()
    private var begins: [String: UInt64] = [:]
    private var ended: [(name: String, pid: Int32, ticks: UInt64)] = []

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["stream", "--signpost", "--style", "ndjson", "--level", "debug", "--predicate", "subsystem == \"app.gitbonsai\" AND category == \"PointsOfInterest\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.receive(handle.availableData) }
        try process.run()
        // `log stream` takes a moment before it delivers; earlier events would be lost.
        Thread.sleep(forTimeInterval: 1)
    }

    func stop() {
        process.terminate()
    }

    func interval(_ name: String, pid: Int32) -> Duration? {
        lock.withLock { ended.first { $0.name == name && $0.pid == pid } }.map { Self.duration(ticks: $0.ticks) }
    }

    private func receive(_ data: Data) {
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any], event["eventType"] as? String == "signpostEvent", let name = event["signpostName"] as? String, let type = event["signpostType"] as? String, let id = event["signpostID"] as? NSNumber, let pid = event["processID"] as? NSNumber, let time = event["machTimestamp"] as? NSNumber else { continue }
                let key = "\(pid).\(id)"
                if type == "begin" {
                    begins[key] = time.uint64Value
                } else if type == "end", let begin = begins.removeValue(forKey: key) {
                    ended.append((name, pid.int32Value, time.uint64Value - begin))
                }
            }
        }
    }

    private static func duration(ticks: UInt64) -> Duration {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return .nanoseconds(Int64(ticks * UInt64(timebase.numer) / UInt64(timebase.denom)))
    }
}
