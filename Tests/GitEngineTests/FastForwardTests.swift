import XCTest
@testable import GitEngine

/// Fast-forwarding a local branch to another ref or commit, checked out here, nowhere, or in another worktree.
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

        let result = try await repo.repository.fastForward("main", to: .local("dev"))

        XCTAssertEqual(result.place, .current)
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
            _ = try await repo.repository.fastForward("main", to: .local("dev"))
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
            _ = try await repo.repository.fastForward("dev", to: .local(base))
            XCTFail("expected a refusal")
        } catch let error as FastForwardError {
            XCTAssertEqual(error, .upToDate(branch: "dev"))
        }
        XCTAssertEqual(try repo.git("rev-parse", "dev"), dev)
    }

    func testMovesABranchCheckedOutNowhereWithoutTouchingTheWorkingTree() async throws {
        let (repo, base, dev) = try makeRepo()
        defer { repo.remove() }
        try repo.git("branch", "old", base)
        try repo.git("switch", "-q", "dev")

        let result = try await repo.repository.fastForward("old", to: .local(dev))

        XCTAssertEqual(result.place, .ref)
        XCTAssertEqual(result.commits, 2)
        XCTAssertEqual(result.commandLine, "git fetch --no-write-fetch-head . \(dev):refs/heads/old")
        XCTAssertEqual(try repo.git("rev-parse", "old"), dev)
        XCTAssertEqual(try repo.git("symbolic-ref", "--short", "HEAD"), "dev")
    }

    func testRefusesADivergedBranchCheckedOutNowhere() async throws {
        let (repo, base, _) = try makeRepo()
        defer { repo.remove() }
        try repo.git("switch", "-q", "-c", "side", base)
        let side = try repo.commit("side", file: "side.txt")
        try repo.git("switch", "-q", "main")

        do {
            _ = try await repo.repository.fastForward("side", to: .local("dev"))
            XCTFail("expected a refusal")
        } catch let error as FastForwardError {
            XCTAssertEqual(error, .notFastForward(branch: "side"))
        }
        XCTAssertEqual(try repo.git("rev-parse", "side"), side)
    }

    func testFetchesARemoteBranchIntoABranchCheckedOutNowhere() async throws {
        let (remote, _, dev) = try makeRepo()
        defer { remote.remove() }
        let local = try FixtureRepo(name: "local")
        defer { local.remove() }
        try local.git("remote", "add", "origin", remote.path)
        try local.git("fetch", "-q", "origin")
        try local.git("reset", "-q", "--hard", "origin/main")
        try local.git("branch", "-q", "feature", "origin/main")

        let result = try await local.repository.fastForward("feature", to: .remote(remote: "origin", branch: "dev"))

        XCTAssertEqual(result.place, .ref)
        XCTAssertEqual(result.commandLine, "git fetch --no-write-fetch-head origin refs/heads/dev:refs/heads/feature")
        XCTAssertEqual(try local.git("rev-parse", "feature"), dev)
        XCTAssertEqual(try local.git("symbolic-ref", "--short", "HEAD"), "main")
    }

    func testMergesInsideTheWorktreeThatHasTheBranch() async throws {
        let (repo, base, dev) = try makeRepo()
        defer { repo.remove() }
        try repo.git("branch", "old", base)
        let worktree = repo.path + "-old"
        try repo.git("worktree", "add", "-q", worktree, "old")
        defer { try? FileManager.default.removeItem(atPath: worktree) }

        let result = try await repo.repository.fastForward("old", to: .local("dev"))

        guard case .worktree = result.place else { return XCTFail("expected the worktree, got \(result.place)") }
        XCTAssertEqual(try FixtureRepo(existing: URL(fileURLWithPath: worktree)).git("rev-parse", "HEAD"), dev)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree + "/two.txt"))
    }
}
