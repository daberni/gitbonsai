import Foundation
import XCTest
@testable import GitEngine

final class RefJumpTests: XCTestCase {
    private func ref(_ name: String, _ kind: RefKind, head: Bool = false) -> Ref {
        let prefix = switch kind {
        case .localBranch: "refs/heads/"
        case .remoteBranch: "refs/remotes/"
        case .tag: "refs/tags/"
        default: "refs/"
        }
        return Ref(fullName: prefix + name, name: name, kind: kind, target: "sha-" + name, isHead: head, upstream: nil, ahead: nil, behind: nil)
    }

    private func worktree(_ path: String, branch: String?, prunable: Bool = false) -> Worktree {
        Worktree(path: path, headSHA: "sha-wt", branch: branch, isMain: false, isBare: false, isDetached: branch == nil, isLocked: false, lockReason: nil, isPrunable: prunable)
    }

    private func names(_ matches: [RefJump.Match]) -> [String] { matches.map(\.target.name) }

    private var sample: [RefJump.Target] {
        RefJump.targets(
            refs: [ref("maintenance", .localBranch), ref("feature/login", .localBranch), ref("main", .localBranch, head: true), ref("origin/main", .remoteBranch(remote: "origin")), ref("origin/HEAD", .remoteBranch(remote: "origin")), ref("v1.0", .tag), ref("login-old", .tag)],
            worktrees: [(worktree("/work/app", branch: "refs/heads/main"), true), (worktree("/work/app-login", branch: "refs/heads/feature/login"), false), (worktree("/work/gone", branch: nil, prunable: true), false)],
            stashes: [Stash(selector: "stash@{0}", commitID: "sha-stash", message: "On main: half-done login form", date: Date())]
        )
    }

    func testEmptyQueryListsKindsInOrderWithTheCheckedOutBranchFirstAndSkipsAliasesAndPrunableWorktrees() {
        XCTAssertEqual(names(RefJump.rank(sample, query: "")), ["main", "maintenance", "feature/login", "app", "app-login", "origin/main", "v1.0", "login-old", "stash@{0}"])
    }

    func testFullNameOrLastSegmentBeatsLongerPrefixMatches() {
        // "main" is a prefix of "maintenance" with the same fuzzy score; the exact name wins, and the remote branch's last segment comes next.
        XCTAssertEqual(Array(names(RefJump.rank(sample, query: "main")).prefix(3)), ["main", "origin/main", "maintenance"])
        // "login" names feature/login exactly by its last segment, ahead of a tag that only starts with it.
        XCTAssertEqual(names(RefJump.rank(sample, query: "login")).first, "feature/login")
    }

    func testEqualMatchesKeepTheKindOrder() {
        // Both start with "app"; the worktree list follows local branches, so among worktrees the earlier one stays first.
        XCTAssertEqual(names(RefJump.rank(sample, query: "app")), ["app", "app-login"])
    }

    func testDetailMatchesWithoutHighlightAndRanksBelowNameHits() throws {
        let matches = RefJump.rank(sample, query: "form")
        XCTAssertEqual(names(matches), ["stash@{0}"])
        XCTAssertEqual(matches.first?.nameRanges, [])
        // "login" in the stash message counts, but below every name that contains it.
        XCTAssertEqual(names(RefJump.rank(sample, query: "login")).last, "stash@{0}")
    }

    func testEveryWordHasToMatchAndRangesHighlightTheName() throws {
        let match = try XCTUnwrap(RefJump.rank(sample, query: "or ma").first)
        XCTAssertEqual(match.target.name, "origin/main")
        XCTAssertEqual(match.nameRanges.map { ("origin/main" as NSString).substring(with: $0) }, ["or", "ma"])
        XCTAssertTrue(RefJump.rank(sample, query: "main zzz").isEmpty)
    }

    func testWorktreesShowTheirBranchShort() {
        XCTAssertEqual(sample.first { $0.name == "app-login" }?.detail, "feature/login")
    }

    func testIDsAreUniqueAcrossKinds() {
        let targets = RefJump.targets(refs: [ref("x", .localBranch), ref("x", .tag)], worktrees: [], stashes: [])
        XCTAssertEqual(Set(targets.map(\.id)).count, 2)
    }

    func testCheckoutRules() {
        let state = RepositoryCommandState(branch: "main", headSHA: "abc")
        let busy = RepositoryCommandState(branch: "main", headSHA: "abc", operation: .rebase)
        let branch = RefJump.Target(kind: .localBranch(isHead: false), name: "dev", commit: "a")
        XCTAssertNil(CommandRules.checkout(branch, state))
        XCTAssertEqual(CommandRules.checkout(branch, busy), .operationInProgress(.rebase))
        XCTAssertEqual(CommandRules.checkout(RefJump.Target(kind: .localBranch(isHead: true), name: "main", commit: "a"), state), .checkedOut)
        XCTAssertNil(CommandRules.checkout(RefJump.Target(kind: .tag, name: "v1", commit: "a"), state))
        XCTAssertEqual(CommandRules.checkout(RefJump.Target(kind: .stash, name: "stash@{0}", commit: "a"), state), .notCheckoutable)
        // Switching to another worktree opens it; a rebase here does not stand in the way.
        XCTAssertNil(CommandRules.checkout(RefJump.Target(kind: .worktree(path: "/w", isCurrent: false), name: "w", commit: "a"), busy))
        XCTAssertEqual(CommandRules.checkout(RefJump.Target(kind: .worktree(path: "/w", isCurrent: true), name: "w", commit: "a"), state), .checkedOut)
    }

    func testGoToRefNeedsACommit() {
        XCTAssertEqual(CommandRules.goToRef(RepositoryCommandState()), .noCommits)
        XCTAssertNil(CommandRules.goToRef(RepositoryCommandState(headSHA: "abc")))
    }
}
