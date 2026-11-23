import Foundation
import XCTest
@testable import GitEngine

final class DeleteEverywhereTests: XCTestCase {
    private var fixture: FixtureRepo!
    private var remote: FixtureRepo!

    /// `main` pushed to a bare `origin` and a bare `backup`.
    override func setUpWithError() throws {
        fixture = try FixtureRepo()
        try fixture.commit("one")
        remote = try FixtureRepo(name: "remote")
        for name in ["origin", "backup"] {
            try remote.git("init", "-q", "--bare", "\(name).git")
            try fixture.git("remote", "add", name, remote.url.appendingPathComponent("\(name).git").path)
            try fixture.git("push", "-q", name, "main")
        }
    }

    override func tearDown() {
        fixture.remove()
        remote.remove()
    }

    private func remoteHas(_ remoteName: String, _ branch: String) throws -> Bool {
        let bare = FixtureRepo(existing: remote.url.appendingPathComponent("\(remoteName).git"))
        return (try? bare.git("rev-parse", "--verify", "-q", "refs/heads/\(branch)")) != nil
    }

    func testFindsSameNameOnEveryRemoteAndUpstreamOfOtherName() async throws {
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.commit("work")
        try fixture.git("push", "-q", "-u", "origin", "feature:topic")
        try fixture.git("push", "-q", "backup", "feature")
        try fixture.git("switch", "-q", "main")

        let deletion = try await fixture.repository.branchDeletion(of: "feature")

        XCTAssertEqual(deletion.targets.map(\.name), ["feature", "origin/topic", "backup/feature"])
        // The work commit is only in the refs being deleted.
        XCTAssertEqual(deletion.targets.map(\.isUnmerged), [true, true, true])
        XCTAssertEqual(deletion.targets.map(\.commandLine), ["git branch -D feature", "git push origin --delete refs/heads/topic", "git push backup --delete refs/heads/feature"])
    }

    func testMergedWhenAnotherRefContainsTheCommits() async throws {
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.commit("work")
        try fixture.git("push", "-q", "origin", "feature")
        try fixture.git("switch", "-q", "main")
        try fixture.git("merge", "-q", "--ff-only", "feature")

        let deletion = try await fixture.repository.branchDeletion(of: "feature")

        XCTAssertEqual(deletion.targets.map(\.name), ["feature", "origin/feature"])
        XCTAssertEqual(deletion.targets.map(\.isUnmerged), [false, false])
    }

    func testDeletesLocalAndRemoteBranches() async throws {
        try fixture.git("switch", "-q", "-c", "feature")
        try fixture.commit("work")
        try fixture.git("push", "-q", "-u", "origin", "feature")
        try fixture.git("push", "-q", "backup", "feature")
        try fixture.git("switch", "-q", "main")
        let deletion = try await fixture.repository.branchDeletion(of: "feature")

        // backup unchecked: it stays.
        try await fixture.repository.delete(deletion.targets.filter { $0.name != "backup/feature" })

        XCTAssertNil(try? fixture.git("rev-parse", "--verify", "-q", "refs/heads/feature"))
        XCTAssertNil(try? fixture.git("rev-parse", "--verify", "-q", "refs/remotes/origin/feature"))
        XCTAssertFalse(try remoteHas("origin", "feature"))
        XCTAssertTrue(try remoteHas("backup", "feature"))
    }
}
