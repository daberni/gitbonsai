import Foundation

/// One measurement: `run` performs `warmup` untimed and `iterations` timed repetitions and returns the timed samples.
struct Benchmark {
    let name: String
    /// The budget AGENTS.md sets for this measurement, if any; shown next to the result, never enforced.
    let budget: Duration?
    let iterations: Int
    /// Launches the app and reads its signposts, so it needs a logged-in session with a window server.
    var launchesApp = false
    let run: (_ warmup: Int, _ iterations: Int) async throws -> [Duration]

    init(_ name: String, budget: Duration?, iterations: Int = 10, run: @escaping (_ warmup: Int, _ iterations: Int) async throws -> [Duration]) {
        self.name = name
        self.budget = budget
        self.iterations = iterations
        self.run = run
    }

    /// A benchmark whose body returns the duration of the part it measures.
    static func timed(_ name: String, budget: Duration?, iterations: Int = 10, _ body: @escaping () async throws -> Duration) -> Benchmark {
        Benchmark(name, budget: budget, iterations: iterations) { warmup, iterations in
            for _ in 0..<warmup { _ = try await body() }
            var samples: [Duration] = []
            for _ in 0..<iterations { samples.append(try await body()) }
            return samples
        }
    }

    /// A benchmark that times all of `body`.
    static func clocked(_ name: String, budget: Duration?, iterations: Int = 10, _ body: @escaping () throws -> Void) -> Benchmark {
        timed(name, budget: budget, iterations: iterations) { try ContinuousClock().measure(body) }
    }
}

/// The summary of one benchmark's samples, in milliseconds, as printed and stored in JSON.
struct BenchmarkResult: Codable {
    let name: String
    let iterations: Int
    let medianMs: Double
    let minMs: Double
    let maxMs: Double
    let budgetMs: Double?

    /// (max − min) / median: how much the samples scatter around the median.
    var spread: Double { medianMs > 0 ? (maxMs - minMs) / medianMs : 0 }

    init(name: String, samples: [Duration], budget: Duration?) {
        let milliseconds = samples.map(\.milliseconds).sorted()
        let middle = milliseconds.count / 2
        self.name = name
        self.iterations = milliseconds.count
        self.medianMs = milliseconds.count % 2 == 1 ? milliseconds[middle] : (milliseconds[middle - 1] + milliseconds[middle]) / 2
        self.minMs = milliseconds.first ?? 0
        self.maxMs = milliseconds.last ?? 0
        self.budgetMs = budget?.milliseconds
    }
}

/// The JSON file `--json` writes and `--compare` reads.
struct BenchmarkReport: Codable {
    var machine: String
    var date: String
    var results: [BenchmarkResult]
}

extension Duration {
    var milliseconds: Double {
        Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    init(seconds: Double) {
        self = .nanoseconds(Int64(seconds * 1e9))
    }
}
