import XCTest
@testable import GitEngine

/// Moving another local branch forward to HEAD without checking it out.
final class FastForwardToHeadTests: XCTestCase {
    /// main has base ← second checked out; `behind` stays at base.
    private func makeRepo() throws -> (repo: FixtureRepo, base: String, head: String) {
        let repo = try FixtureRepo()
        let base = try repo.commit("base")
        try repo.git("branch", "behind")
        let head = try repo.commit("second", file: "second.txt")
        return (repo, base, head)
    }

    func testFastForwardsABranchCheckedOutNowhere() async throws {
        let (repo, _, head) = try makeRepo()
        defer { repo.remove() }

        let (result, place) = try await repo.repository.fastForwardBranchToHead("behind")

        XCTAssertEqual(place, .ref)
        XCTAssertEqual(result.commits, 1)
        XCTAssertEqual(result.commandLine, "git fetch --no-write-fetch-head . HEAD:refs/heads/behind")
        XCTAssertEqual(try repo.git("rev-parse", "refs/heads/behind"), head)
        XCTAssertEqual(try repo.git("symbolic-ref", "--short", "HEAD"), "main")
    }

    func testMergesInsideTheWorktreeThatHasTheBranchCheckedOut() async throws {
        let (repo, _, head) = try makeRepo()
        defer { repo.remove() }
        let worktree = repo.path + "-behind"
        try repo.git("worktree", "add", "-q", worktree, "behind")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let (result, place) = try await repo.repository.fastForwardBranchToHead("behind")

        guard case .worktree = place else { return XCTFail("expected the worktree, got \(place)") }
        XCTAssertEqual(result.commits, 1)
        XCTAssertEqual(try FixtureRepo(existing: URL(fileURLWithPath: worktree)).git("rev-parse", "HEAD"), head)
        // The worktree's files moved with the branch, which a bare ref update would not do.
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/second.txt"))
    }

    func testRefusesADivergedBranchAndTheCurrentOne() async throws {
        let (repo, base, _) = try makeRepo()
        defer { repo.remove() }
        try repo.git("switch", "-q", "behind")
        let own = try repo.commit("own", file: "own.txt")
        try repo.git("switch", "-q", "main")

        do {
            _ = try await repo.repository.fastForwardBranchToHead("behind")
            XCTFail("a diverged branch must not move")
        } catch let error as FastForwardError {
            XCTAssertEqual(error, .notFastForward(branch: "behind"))
        }
        XCTAssertEqual(try repo.git("rev-parse", "refs/heads/behind"), own)
        XCTAssertNotEqual(own, base)

        do {
            _ = try await repo.repository.fastForwardBranchToHead("main")
            XCTFail("the checked-out branch is not moved here")
        } catch let error as FastForwardError {
            XCTAssertEqual(error, .isCurrentBranch(branch: "main"))
        }
    }
}
