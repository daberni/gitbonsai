import Foundation
import GitEngine
import GraphLayout
import TextViewerModel

/// The benchmarks with the budget AGENTS.md sets for each. Inputs are built inside each benchmark, so a filtered run prepares only what it measures.
/// Engine work runs in this process; what the app itself does is measured in the app, from its signposts.
enum Cases {
    static let syntheticCommits = 100_000
    static let syntheticBranches = 8
    static let changedFiles = 10_000

    static var all: [Benchmark] {
        [historyOpen, layout, search, fileListFirstRows, textOpen, textHighlight]
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

    static let largeFileLines = 100_000

    /// Opening a 100k-line file in the text viewer's model: decoding its bytes and indexing its lines, what happens before the first lines can show.
    private static var textOpen: Benchmark {
        Benchmark("text.open100k", budget: .milliseconds(100), iterations: 5) { warmup, iterations in
            let data = Fixtures.largeSourceFile(lines: largeFileLines)
            return try await Benchmark.clocked("", budget: nil) {
                _ = TextDocument(data: data)
            }.run(warmup, iterations)
        }
    }

    /// Colours for the first screen of a 100k-line Swift file: tree-sitter parses the whole file off the main thread, then the first 300 lines are queried.
    private static var textHighlight: Benchmark {
        Benchmark.timed("text.highlight100k.first300", budget: nil, iterations: 5) {
            let document = TextDocument(data: Fixtures.largeSourceFile(lines: largeFileLines))
            let start = ContinuousClock.now
            guard let highlighter = await SyntaxHighlighter.make(for: document, language: .swift) else { throw FixtureError("no highlighter") }
            let firstScreen = NSRange(location: 0, length: NSMaxRange(document.range(ofLine: 299)))
            _ = await highlighter.spans(in: firstScreen)
            return start.duration(to: .now)
        }
    }
}
