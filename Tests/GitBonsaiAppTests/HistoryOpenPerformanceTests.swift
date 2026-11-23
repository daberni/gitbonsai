import XCTest
import GitEngine
import GraphLayout
@testable import GitBonsaiApp

/// From opening a repository to its first 300 history rows laid out, on a 100k-commit repository built by `scripts/make-synthetic-repo.sh`.
@MainActor
final class HistoryOpenPerformanceTests: XCTestCase {
    nonisolated(unsafe) private static var repositoryURL: URL?

    private func syntheticRepository() throws -> URL {
        if let url = Self.repositoryURL { return url }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-history-open-\(UUID().uuidString)")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/make-synthetic-repo.sh")
        let process = Process()
        process.executableURL = script
        process.arguments = [url.path, "100000", "8"]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        Self.repositoryURL = url
        return url
    }

    override class func tearDown() {
        if let url = repositoryURL { try? FileManager.default.removeItem(at: url) }
        repositoryURL = nil
    }

    /// Time until the history holds `count` commits, measured like a tab opening the repository.
    private func timeToFirstRows(_ count: Int, in url: URL, order: HistoryOrder) async -> Duration {
        let model = GraphViewModel(location: RepositoryLocation(root: url.path, commonDirectory: url.appendingPathComponent(".git").path), historyOrder: order)
        let start = ContinuousClock.now
        let elapsed: Duration = await withCheckedContinuation { continuation in
            var resumed = false
            model.onRowsAppended = { _ in
                guard !resumed, model.history.commitCount >= count else { return }
                resumed = true
                continuation.resume(returning: start.duration(to: .now))
            }
            model.load()
        }
        model.loadTask?.cancel()
        return elapsed
    }

    /// The budget holds for every order once the commit-graph exists; without it git walks the whole history first, which is only reported.
    func testPerformanceFirstThreeHundredCommitsOnScreen() async throws {
        let url = try syntheticRepository()
        for order in HistoryOrder.allCases {
            let withoutGraph = await timeToFirstRows(300, in: url, order: order)
            print("100,000 commits without commit-graph, \(order), first 300 rows on screen: \(withoutGraph)")
        }
        let repository = Repository(path: url.path)
        let wrote = await repository.writeCommitGraphIfMissing()
        XCTAssertTrue(wrote)
        for order in HistoryOrder.allCases {
            _ = await timeToFirstRows(300, in: url, order: order)
            let elapsed = await timeToFirstRows(300, in: url, order: order)
            print("100,000 commits with commit-graph, \(order), first 300 rows on screen: \(elapsed)")
            XCTAssertLessThan(elapsed, .milliseconds(100), "\(order)")
        }
    }

    /// The layout budget for the whole history, in the order git gives each choice; date orders interleave branches more than the synthetic history in `GraphLayoutTests`.
    func testPerformanceHundredThousandCommitsLaidOutInEveryOrder() async throws {
        let url = try syntheticRepository()
        let repository = Repository(path: url.path)
        for order in HistoryOrder.allCases {
            var options = LogOptions()
            options.order = order
            var commits: [Commit] = []
            for try await commit in repository.log(options) { commits.append(commit) }
            let start = ContinuousClock.now
            var layout = GraphLayout()
            for commit in commits { _ = layout.append(commit) }
            let elapsed = start.duration(to: .now)
            print("100,000 commits, \(order), laid out in \(elapsed), \(layout.maxLaneCount) lanes")
            XCTAssertEqual(commits.count, 100_000)
            XCTAssertLessThan(elapsed, .seconds(2), "\(order)")
        }
    }
}
