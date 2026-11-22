import Foundation
import XCTest
@testable import GitEngine

final class RefPickerTests: XCTestCase {
    private var fixture: FixtureRepo!
    private var remote: FixtureRepo!

    override func setUpWithError() throws {
        fixture = try FixtureRepo()
        remote = try FixtureRepo(name: "remote")
    }

    override func tearDown() {
        fixture.remove()
        remote.remove()
    }

    func testRefTipsPeelAnnotatedTagsAndSkipRemoteHead() async throws {
        let first = try fixture.commit("first commit")
        try fixture.git("tag", "-a", "v1.0", "-m", "release message", first)
        let second = try fixture.commit("zweiter Commit mit Umlaut", file: "ü.txt")
        try fixture.git("tag", "light")
        try fixture.git("branch", "feature/ünï", first)
        try remote.git("init", "-q", "--bare", "origin.git")
        try fixture.git("remote", "add", "origin", remote.url.appendingPathComponent("origin.git").path)
        try fixture.git("push", "-q", "origin", "main")
        try fixture.git("remote", "set-head", "origin", "main")
        // A tag of a tree is no start point.
        try fixture.git("tag", "tree-tag", "HEAD^{tree}")

        let tips = try await fixture.repository.refTips()
        let byName = Dictionary(uniqueKeysWithValues: tips.map { ($0.fullName, $0) })

        XCTAssertNil(byName["refs/remotes/origin/HEAD"])
        XCTAssertNil(byName["refs/tags/tree-tag"])
        let annotated = try XCTUnwrap(byName["refs/tags/v1.0"])
        XCTAssertEqual(annotated.commit.sha, first)
        XCTAssertEqual(annotated.commit.subject, "first commit")
        XCTAssertEqual(annotated.kind, .tag)
        XCTAssertEqual(byName["refs/tags/light"]?.commit.sha, second)
        XCTAssertEqual(byName["refs/heads/feature/ünï"]?.name, "feature/ünï")
        XCTAssertEqual(byName["refs/heads/main"]?.commit.subject, "zweiter Commit mit Umlaut")
        let originMain = try XCTUnwrap(byName["refs/remotes/origin/main"])
        XCTAssertEqual(originMain.kind, .remoteBranch(remote: "origin"))
        XCTAssertEqual(originMain.commit.date, ISO8601DateFormatter().date(from: "2024-01-01T12:00:00Z"))
    }

    func testRefTipsOfEmptyRepository() async throws {
        let tips = try await fixture.repository.refTips()
        XCTAssertTrue(tips.isEmpty)
    }

    func testCommitSummaryResolvesShortSHAAndRejectsOthers() async throws {
        let sha = try fixture.commit("subject line")
        let summary = await fixture.repository.commitSummary(String(sha.prefix(7)))
        XCTAssertEqual(summary?.sha, sha)
        XCTAssertEqual(summary?.subject, "subject line")
        let none = await fixture.repository.commitSummary("deadbeef")
        XCTAssertNil(none)
        let option = await fixture.repository.commitSummary("--all")
        XCTAssertNil(option)
    }

    func testBranchNameValidation() async throws {
        try fixture.commit("one")
        try fixture.git("switch", "-q", "-c", "other")
        try fixture.git("switch", "-q", "main")
        let repository = fixture.repository
        for name in ["feature/x", "fix-1", "ünï"] {
            let valid = await repository.isValidBranchName(name)
            XCTAssertTrue(valid, name)
        }
        // "@{-1}" is a valid shorthand for the previous branch, but no name for a new one.
        for name in ["", "a..b", "with space", "-dash", "end.lock", "trailing/", "@{-1}", "a:b", "x~1"] {
            let valid = await repository.isValidBranchName(name)
            XCTAssertFalse(valid, name)
        }
    }

    // MARK: Catalog

    private func summary(_ sha: String, _ subject: String = "", daysAgo: Double = 0) -> CommitSummary {
        CommitSummary(sha: sha, date: Date(timeIntervalSince1970: 1_700_000_000 - daysAgo * 86_400), subject: subject)
    }

    private func catalog() -> RefCatalog {
        let tips = [
            RefTip(fullName: "refs/heads/main", name: "main", kind: .localBranch, commit: summary("aaaa1111")),
            RefTip(fullName: "refs/heads/feature/login", name: "feature/login", kind: .localBranch, commit: summary("bbbb2222")),
            RefTip(fullName: "refs/remotes/upstream/main", name: "upstream/main", kind: .remoteBranch(remote: "upstream"), commit: summary("cccc3333")),
            RefTip(fullName: "refs/remotes/origin/feature/login", name: "origin/feature/login", kind: .remoteBranch(remote: "origin"), commit: summary("bbbb2222")),
            RefTip(fullName: "refs/tags/v1", name: "v1", kind: .tag, commit: summary("dddd4444", daysAgo: 10)),
            RefTip(fullName: "refs/tags/v2", name: "v2", kind: .tag, commit: summary("eeee5555", daysAgo: 1)),
        ]
        return RefCatalog(tips: tips, current: [.head(branch: "main", commit: summary("aaaa1111")), .commit(summary("ffff6666", "Fix login"))])
    }

    func testCatalogOrdersSectionsAndMarksTheCheckedOutBranch() {
        let groups = catalog().groups(matching: "")
        XCTAssertEqual(groups.map(\.section), [.current, .local, .remote("origin"), .remote("upstream"), .tags])
        XCTAssertEqual(groups[1].matches.map(\.item.title), ["feature/login", "main"])
        XCTAssertEqual(groups[1].matches[1].item.kind, .localBranch(isHead: true))
        XCTAssertEqual(groups[4].matches.map(\.item.title), ["v2", "v1"], "newest tag first")
        XCTAssertEqual(groups[0].matches[0].item.revision, "HEAD")
    }

    func testCatalogFilterHighlightsAndDropsEmptySections() {
        let groups = catalog().groups(matching: "LOGIN")
        XCTAssertEqual(groups.map(\.section), [.current, .local, .remote("origin")])
        XCTAssertEqual(groups[0].matches.map(\.item.title), ["ffff666"], "the selected commit matches by subject")
        XCTAssertEqual(groups[1].matches.first?.titleRanges, [NSRange(location: 8, length: 5)])
        XCTAssertEqual(groups[2].matches.first?.titleRanges, [NSRange(location: 15, length: 5)])
    }

    func testCatalogOffersAResolvedCommitAndSHAPrefixMatches() {
        let resolved = summary("bbbb2222ffff", "some commit")
        let groups = catalog().groups(matching: "bbbb", resolved: resolved)
        XCTAssertEqual(groups.map(\.section), [.local, .remote("origin"), .commit])
        XCTAssertEqual(groups.last?.matches.first?.item.revision, "bbbb2222ffff")
        XCTAssertTrue(RefCatalog.looksLikeSHA("bbbb"))
        XCTAssertFalse(RefCatalog.looksLikeSHA("bbb"))
        XCTAssertFalse(RefCatalog.looksLikeSHA("feature"))
        XCTAssertTrue(catalog().groups(matching: "nothing").isEmpty)
    }
}
