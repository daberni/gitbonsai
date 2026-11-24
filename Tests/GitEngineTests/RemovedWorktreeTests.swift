import Foundation
import XCTest
@testable import GitEngine

/// A tab that shows a linked worktree which is removed outside the app.
final class RemovedWorktreeTests: XCTestCase {
    func testDiffInRemovedWorktreeFailsInsteadOfReportingNoChanges() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("one", file: "a.txt", contents: "one\n")
        let commitID = try fixture.commit("two", file: "a.txt", contents: "one\ntwo\n")
        let worktreePath = fixture.url.appendingPathComponent("wt-feature").path
        try fixture.git("worktree", "add", "-q", "-b", "feature", worktreePath)
        let worktree = Repository(path: worktreePath)
        var commits: [Commit] = []
        for try await commit in worktree.log() { commits.append(commit) }
        let commit = try XCTUnwrap(commits.first)
        XCTAssertEqual(commit.id, commitID)
        let before = try await worktree.diff(of: "a.txt", in: .commit(commit))
        XCTAssertNotNil(before)

        try fixture.git("worktree", "remove", worktreePath)
        try fixture.git("branch", "-D", "feature")

        do {
            let after = try await worktree.diff(of: "a.txt", in: .commit(commit))
            XCTFail("A diff read in a removed worktree must fail, not return \(String(describing: after))")
        } catch let error as MissingWorkingDirectory {
            XCTAssertEqual(error.path, worktreePath)
        }
    }

    func testReplacementIsTheMainWorktreeOnceTheShownOneIsGone() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("one")
        let worktreePath = fixture.url.appendingPathComponent("wt-feature").path
        try fixture.git("worktree", "add", "-q", "-b", "feature", worktreePath)
        let commonDirectory = fixture.url.appendingPathComponent(".git").path

        let whileThere = await Repository.replacementWorktree(for: worktreePath, commonDirectory: commonDirectory)
        XCTAssertNil(whileThere)

        try fixture.git("worktree", "remove", worktreePath)
        let replacement = await Repository.replacementWorktree(for: worktreePath, commonDirectory: commonDirectory)
        XCTAssertEqual(replacement.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, fixture.url.resolvingSymlinksInPath().path)
    }
}
