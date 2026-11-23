import XCTest
@testable import GitEngine

/// Fast-forwarding the checked-out branch to another ref or commit.
final class FastForwardTests: XCTestCase {
    /// main at `base`, `dev` two commits ahead of it; main checked out.
    private func makeRepo() throws -> (repo: FixtureRepo, base: String, dev: String) {
        let repo = try FixtureRepo()
        let base = try repo.commit("base")
        try repo.git("switch", "-q", "-c", "dev")
        try repo.commit("one", file: "one.txt")
        let dev = try repo.commit("two", file: "two.txt")
        try repo.git("switch", "-q", "main")
        return (repo, base, dev)
    }

    func testFastForwardsTheCurrentBranchWithMergeFFOnly() async throws {
        let (repo, _, dev) = try makeRepo()
        defer { repo.remove() }

        let result = try await repo.repository.fastForwardCurrentBranch(to: "dev")

        XCTAssertEqual(result.branch, "main")
        XCTAssertEqual(result.commits, 2)
        XCTAssertEqual(result.commandLine, "git merge --ff-only dev")
        XCTAssertEqual(try repo.git("rev-parse", "HEAD"), dev)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.path + "/two.txt"))
    }

    func testRefusesADivergedBranchAndChangesNothing() async throws {
        let (repo, base, _) = try makeRepo()
        defer { repo.remove() }
        let own = try repo.commit("own", file: "own.txt")

        do {
            _ = try await repo.repository.fastForwardCurrentBranch(to: "dev")
            XCTFail("expected a refusal")
        } catch let error as FastForwardError {
            XCTAssertEqual(error, .notFastForward(branch: "main"))
        }
        XCTAssertEqual(try repo.git("rev-parse", "HEAD"), own)
        XCTAssertNotEqual(own, base)
    }

    func testRefusesATargetTheBranchAlreadyContains() async throws {
        let (repo, base, dev) = try makeRepo()
        defer { repo.remove() }
        try repo.git("switch", "-q", "dev")

        do {
            _ = try await repo.repository.fastForwardCurrentBranch(to: base)
            XCTFail("expected a refusal")
        } catch let error as FastForwardError {
            XCTAssertEqual(error, .upToDate(branch: "dev"))
        }
        XCTAssertEqual(try repo.git("rev-parse", "dev"), dev)
    }

    func testFastForwardsToARemoteBranch() async throws {
        let (remote, _, dev) = try makeRepo()
        defer { remote.remove() }
        let local = try FixtureRepo(name: "local")
        defer { local.remove() }
        try local.git("remote", "add", "origin", remote.path)
        try local.git("fetch", "-q", "origin")
        try local.git("reset", "-q", "--hard", "origin/main")

        let result = try await local.repository.fastForwardCurrentBranch(to: "refs/remotes/origin/dev")

        XCTAssertEqual(result.commandLine, "git merge --ff-only refs/remotes/origin/dev")
        XCTAssertEqual(try local.git("rev-parse", "HEAD"), dev)
    }

    func testRefusesADetachedHead() async throws {
        let (repo, base, _) = try makeRepo()
        defer { repo.remove() }
        try repo.git("switch", "-q", "--detach", base)

        do {
            _ = try await repo.repository.fastForwardCurrentBranch(to: "dev")
            XCTFail("expected a refusal")
        } catch let error as FastForwardError {
            XCTAssertEqual(error, .detachedHead)
        }
        XCTAssertEqual(try repo.git("rev-parse", "HEAD"), base)
    }
}
