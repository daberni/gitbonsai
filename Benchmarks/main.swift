import Foundation

/// `swift run -c release Benchmarks [--filter <text>] [--engine-only] [--iterations <n>] [--warmup <n>] [--json <path>] [--compare <baseline.json>] [--threshold <percent>] [--min-delta <ms>]`
///
/// Prints a table of every benchmark's median, min and spread next to its AGENTS.md budget. `--compare` adds the median of a baseline from the same machine and fails (exit 1) when a median regresses by more than the threshold (default 20 %) and by at least `--min-delta` (default 1 ms); budgets are shown, never enforced. Engine cases run in this process; app cases launch the app isolated (`scripts/launch-dev.sh`) and read the signpost interval it emits.
struct Options {
    var filter: String?
    /// Leaves out the benchmarks that launch the app, for machines without a window server such as CI runners.
    var engineOnly = false
    var iterations: Int?
    var warmup = 1
    var jsonPath: String?
    var comparePath: String?
    var threshold = 20.0
    /// Changes smaller than this many milliseconds never count as a regression; sub-millisecond medians move by more than 20 % from scheduler noise alone.
    var minimumDelta = 1.0

    init(_ arguments: [String]) throws {
        var remaining = arguments[...]
        func value(for flag: String) throws -> String {
            guard let value = remaining.popFirst() else { throw FixtureError("\(flag) needs a value") }
            return value
        }
        while let flag = remaining.popFirst() {
            switch flag {
            case "--filter": filter = try value(for: flag)
            case "--engine-only": engineOnly = true
            case "--iterations": iterations = Int(try value(for: flag))
            case "--warmup": warmup = Int(try value(for: flag)) ?? warmup
            case "--json": jsonPath = try value(for: flag)
            case "--compare": comparePath = try value(for: flag)
            case "--threshold": threshold = Double(try value(for: flag)) ?? threshold
            case "--min-delta": minimumDelta = Double(try value(for: flag)) ?? minimumDelta
            default: throw FixtureError("unknown argument \(flag)")
            }
        }
    }
}

func formatted(_ milliseconds: Double?) -> String {
    guard let milliseconds else { return "–" }
    return milliseconds >= 1_000 ? String(format: "%.2f s", milliseconds / 1_000) : String(format: "%.2f ms", milliseconds)
}

func padded(_ text: String, _ width: Int, left: Bool = false) -> String {
    let padding = String(repeating: " ", count: max(0, width - text.count))
    return left ? text + padding : padding + text
}

func machineDescription() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    var brand = [CChar](repeating: 0, count: max(size, 1))
    sysctlbyname("machdep.cpu.brand_string", &brand, &size, nil, 0)
    let cpu = String(decoding: brand.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return "\(cpu), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
}

let options: Options
do {
    options = try Options(Array(CommandLine.arguments.dropFirst()))
} catch {
    log("\(error)")
    exit(2)
}

let baseline: [String: BenchmarkResult]
if let comparePath = options.comparePath {
    do {
        let report = try JSONDecoder().decode(BenchmarkReport.self, from: Data(contentsOf: URL(fileURLWithPath: comparePath)))
        baseline = Dictionary(report.results.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    } catch {
        log("Cannot read baseline \(comparePath): \(error)")
        exit(2)
    }
} else {
    baseline = [:]
}

let selected = Cases.all.filter { (options.filter.map($0.name.contains) ?? true) && !(options.engineOnly && $0.launchesApp) }
if selected.isEmpty {
    log("No benchmark matches \(options.filter ?? "")")
    exit(2)
}

let nameWidth = max(selected.map(\.name.count).max() ?? 0, 9)
var header = padded("benchmark", nameWidth, left: true) + padded("median", 11) + padded("min", 11) + padded("spread", 8) + padded("budget", 11)
if options.comparePath != nil { header += padded("baseline", 11) + padded("change", 9) }
print(header)
print(String(repeating: "-", count: header.count))

var results: [BenchmarkResult] = []
var regressions: [String] = []
for benchmark in selected {
    let samples: [Duration]
    do {
        samples = try await benchmark.run(options.warmup, options.iterations ?? benchmark.iterations)
    } catch {
        log("\(benchmark.name) failed: \(error)")
        exit(2)
    }
    let result = BenchmarkResult(name: benchmark.name, samples: samples, budget: benchmark.budget)
    results.append(result)
    var line = padded(result.name, nameWidth, left: true) + padded(formatted(result.medianMs), 11) + padded(formatted(result.minMs), 11) + padded(String(format: "%.0f %%", result.spread * 100), 8) + padded(formatted(result.budgetMs), 11)
    if options.comparePath != nil {
        if let reference = baseline[result.name] {
            let change = (result.medianMs / reference.medianMs - 1) * 100
            let regressed = change > options.threshold && result.medianMs - reference.medianMs >= options.minimumDelta
            if regressed { regressions.append(result.name) }
            line += padded(formatted(reference.medianMs), 11) + padded(String(format: "%+.0f %%", change), 9) + (regressed ? "  REGRESSED" : "")
        } else {
            line += padded("–", 11) + padded("new", 9)
        }
    }
    print(line)
}

if let jsonPath = options.jsonPath {
    let report = BenchmarkReport(machine: machineDescription(), date: ISO8601DateFormatter().string(from: Date()), results: results)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        try encoder.encode(report).write(to: URL(fileURLWithPath: jsonPath))
    } catch {
        log("Cannot write \(jsonPath): \(error)")
        exit(2)
    }
}

if !regressions.isEmpty {
    print("\nMedian regressed by more than \(Int(options.threshold)) % against the baseline: \(regressions.joined(separator: ", "))")
    exit(1)
}
