import Foundation
import GitEngine
import GraphLayout

/// The benchmarks with the budget AGENTS.md sets for each. Inputs are built inside each benchmark, so a filtered run prepares only what it measures.
/// Engine work runs in this process; what the app itself does is measured in the app, from its signposts.
enum Cases {
    static let syntheticCommits = 100_000
    static let syntheticBranches = 8
    static let changedFiles = 10_000

    static var all: [Benchmark] {
        [historyOpen, layout, search, fileListFirstRows]
    }

    /// The app opening the synthetic repository with its commit-graph, until the first 300 history rows are laid out (`repository.open`).
    private static var historyOpen: Benchmark {
        var benchmark = Benchmark.timed("history.open300", budget: .milliseconds(100), iterations: 5) {
            let url = try await Fixtures.syntheticRepository(commits: syntheticCommits, branches: syntheticBranches)
            return try await AppRun.interval("repository.open", repository: url)
        }
        benchmark.launchesApp = true
        return benchmark
    }

    private static var layout: Benchmark {
        Benchmark("layout.100k", budget: .seconds(2), iterations: 5) { warmup, iterations in
            let commits = Fixtures.syntheticHistory(count: syntheticCommits, strands: syntheticBranches)
            return try await Benchmark.clocked("", budget: nil) {
                var layout = GraphLayout()
                layout.append(contentsOf: commits)
            }.run(warmup, iterations)
        }
    }

    /// A search that matches nothing scans every field of 100k commits, the slowest case of typing into the search.
    private static var search: Benchmark {
        Benchmark("search.100k.miss", budget: .milliseconds(300), iterations: 5) { warmup, iterations in
            let commits = Fixtures.searchableHistory(count: syntheticCommits)
            guard let search = CommitSearch("zzz-not-there") else { throw FixtureError("no search") }
            return try await Benchmark.clocked("", budget: nil) {
                _ = search.matchingIndices(in: commits, range: 0..<commits.count, refNames: [:])
            }.run(warmup, iterations)
        }
    }

    /// The app showing a commit that changes 10,000 files, from handing the rows to the detail panel's list until the list draws them (`files.load`).
    private static var fileListFirstRows: Benchmark {
        var benchmark = Benchmark.timed("files.10k.firstRows", budget: .milliseconds(100), iterations: 5) {
            let url = try await Fixtures.wideCommit(files: changedFiles)
            return try await AppRun.interval("files.load", repository: url)
        }
        benchmark.launchesApp = true
        return benchmark
    }
}
