import XCTest
@testable import GitEngine

/// A working-tree diff rewrites the index under `index.lock` when stat information is stale, whatever `GIT_OPTIONAL_LOCKS` says.
/// Running next to a checkout of the same working tree, from the same or another `Repository`, it must not make the checkout fail.
final class IndexLockTests: XCTestCase {
    func testWorkingTreeReadsDoNotBreakConcurrentCheckouts() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        for index in 0..<200 { try fixture.write("files/\(index).txt", "line \(index)\n") }
        try fixture.commit("base", file: "shared.txt", contents: "main\n")
        try fixture.git("switch", "-q", "-c", "other")
        try fixture.commit("other", file: "shared.txt", contents: "other\n")
        try fixture.git("switch", "-q", "main")

        let reader = Repository(path: fixture.path)
        let writer = Repository(path: fixture.path)
        var failures: [String] = []
        for round in 0..<30 {
            try touchTrackedFiles(in: fixture)
            let target = round.isMultiple(of: 2) ? "other" : "main"
            async let unstaged = reader.workingStats(staged: false)
            async let fileDiff = reader.diff(of: "files/0.txt", in: .unstaged)
            do {
                try await writer.checkout(.localBranch(target))
            } catch {
                failures.append("round \(round): \(error)")
            }
            _ = try await (unstaged, fileDiff)
        }
        XCTAssertEqual(failures, [])
    }

    /// New modification times without content changes leave every index entry stat-dirty.
    private func touchTrackedFiles(in fixture: FixtureRepo) throws {
        let now = Date()
        for path in try fixture.git("ls-files").split(separator: "\n") {
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fixture.url.appendingPathComponent(String(path)).path)
        }
    }
}
