import Foundation
import XCTest
@testable import GitEngine

final class CommandRankingTests: XCTestCase {
    private func ids(_ results: [CommandRanking.Result]) -> [String] { results.map(\.id) }

    func testFuzzyMatchNeedsCharactersInOrderAndIgnoresCaseAndUmlauts() throws {
        XCTAssertNotNil(FuzzyMatch.match("pll", in: "Pull"))
        XCTAssertNil(FuzzyMatch.match("llp", in: "Pull"))
        XCTAssertNotNil(FuzzyMatch.match("OFFNEN", in: "Im Terminal öffnen"))
        XCTAssertEqual(FuzzyMatch.match("", in: "Pull"), FuzzyMatch(score: 0, ranges: []))
    }

    func testRangesPreferWordStartsAndAreMergedUTF16Ranges() throws {
        let text = "Im Terminal öffnen"
        let match = try XCTUnwrap(FuzzyMatch.match("te", in: text))
        // "te" exists inside "Terminal" right at its word start, not in "öffnen".
        XCTAssertEqual(match.ranges, [NSRange(location: 3, length: 2)])
        let initials = try XCTUnwrap(FuzzyMatch.match("ito", in: text))
        XCTAssertEqual(initials.ranges.map { (text as NSString).substring(with: $0) }, ["I", "T", "ö"])
    }

    func testEveryCharacterBeforeAnEmojiCountsInUTF16() throws {
        let text = "🌳 Pull"
        let match = try XCTUnwrap(FuzzyMatch.match("pull", in: text))
        XCTAssertEqual(match.ranges, [NSRange(location: 3, length: 4)])
    }

    func testPrefixAndWordStartsBeatScatteredHits() throws {
        let candidates = [
            CommandRanking.Candidate(id: "stash-apply", title: "Stash apply popular"),
            CommandRanking.Candidate(id: "pull", title: "Pull"),
            CommandRanking.Candidate(id: "push", title: "Push"),
        ]
        XCTAssertEqual(ids(CommandRanking.rank(candidates, query: "pu", recent: [])), ["pull", "push", "stash-apply"])
        XCTAssertEqual(ids(CommandRanking.rank(candidates, query: "pul", recent: [])), ["pull", "stash-apply"])
    }

    func testKeywordsMatchWithoutHighlightingTheTitle() throws {
        let candidates = [CommandRanking.Candidate(id: "terminal", title: "Im Terminal öffnen", keywords: ["shell", "iTerm"])]
        let result = try XCTUnwrap(CommandRanking.rank(candidates, query: "shell", recent: []).first)
        XCTAssertEqual(result.id, "terminal")
        XCTAssertEqual(result.titleRanges, [])
    }

    func testATitleWordBeatsTheSameWordAsKeyword() throws {
        let candidates = [
            CommandRanking.Candidate(id: "settings", title: "Einstellungen …", keywords: ["editor", "terminal"]),
            CommandRanking.Candidate(id: "editor", title: "Im Editor öffnen"),
        ]
        XCTAssertEqual(ids(CommandRanking.rank(candidates, query: "editor", recent: [])), ["editor", "settings"])
    }

    func testEveryQueryWordMustMatchInAnyOrder() throws {
        let candidates = [
            CommandRanking.Candidate(id: "tags", title: "Tags pushen"),
            CommandRanking.Candidate(id: "push", title: "Push"),
        ]
        XCTAssertEqual(ids(CommandRanking.rank(candidates, query: "push tags", recent: [])), ["tags"])
    }

    func testRecentlyUsedCommandsComeFirstInRecencyOrder() throws {
        let candidates = ["fetch", "pull", "push", "stash"].map { CommandRanking.Candidate(id: $0, title: $0.capitalized) }
        XCTAssertEqual(ids(CommandRanking.rank(candidates, query: "", recent: ["stash", "pull"])), ["stash", "pull", "fetch", "push"])
        // With a query, a recent match leads even when another one matches better.
        XCTAssertEqual(ids(CommandRanking.rank(candidates, query: "p", recent: ["push"])), ["push", "pull"])
    }

    func testDisabledCommandsStayListedBehindEnabledOnes() throws {
        let candidates = [
            CommandRanking.Candidate(id: "pull", title: "Pull", isEnabled: false),
            CommandRanking.Candidate(id: "push", title: "Push"),
        ]
        XCTAssertEqual(ids(CommandRanking.rank(candidates, query: "pu", recent: ["pull"])), ["push", "pull"])
    }
}

final class CommandRulesTests: XCTestCase {
    private let clean = RepositoryCommandState(branch: "main", headSHA: "abc", upstream: "origin/main", remotes: ["origin"])

    func testPullNeedsBranchRemoteUpstreamAndNoRunningOperation() {
        XCTAssertNil(CommandRules.pull(clean))
        var state = clean
        state.upstream = nil
        XCTAssertEqual(CommandRules.pull(state), .noUpstream)
        state.remotes = []
        XCTAssertEqual(CommandRules.pull(state), .noRemote)
        state.branch = nil
        XCTAssertEqual(CommandRules.pull(state), .detachedHead)
        var rebasing = clean
        rebasing.operation = .rebase
        XCTAssertEqual(CommandRules.pull(rebasing), .operationInProgress(.rebase))
    }

    func testFirstPushNeedsNoUpstreamButARemoteAndACommit() {
        var state = clean
        state.upstream = nil
        XCTAssertNil(CommandRules.push(state))
        state.headSHA = nil
        XCTAssertEqual(CommandRules.push(state), .noCommits)
        XCTAssertEqual(CommandRules.pushTags(RepositoryCommandState(branch: "main")), .noRemote)
    }

    func testIndexCommandsFollowTheCounts() {
        var state = clean
        XCTAssertEqual(CommandRules.commit(state), .nothingStaged)
        XCTAssertEqual(CommandRules.stageAll(state), .nothingToStage)
        XCTAssertEqual(CommandRules.unstageAll(state), .nothingToUnstage)
        XCTAssertEqual(CommandRules.stash(state), .noChanges)
        state.stagedCount = 1
        state.unstagedCount = 2
        XCTAssertNil(CommandRules.commit(state))
        XCTAssertNil(CommandRules.stageAll(state))
        XCTAssertNil(CommandRules.unstageAll(state))
        XCTAssertNil(CommandRules.stash(state))
        state.conflictCount = 1
        XCTAssertEqual(CommandRules.commit(state), .conflicts)
    }

    func testDiscardAllOnlyCountsTrackedChanges() throws {
        let untracked = StatusEntry(path: "new.txt", originalPath: nil, indexState: .unmodified, worktreeState: .unmodified, isUntracked: true, isIgnored: false, conflict: nil, isSubmodule: false)
        let edited = StatusEntry(path: "a.txt", originalPath: nil, indexState: .unmodified, worktreeState: .modified, isUntracked: false, isIgnored: false, conflict: nil, isSubmodule: false)
        let branch = BranchStatus(headSHA: "abc", branch: "main", upstream: nil, ahead: 0, behind: 0)
        let onlyUntracked = RepositoryCommandState(status: RepositoryStatus(branch: branch, entries: [untracked]), remotes: [], stashCount: 0, operation: nil)
        XCTAssertEqual(CommandRules.discardAll(onlyUntracked), .noTrackedChanges)
        XCTAssertNil(CommandRules.stageAll(onlyUntracked))
        let both = RepositoryCommandState(status: RepositoryStatus(branch: branch, entries: [untracked, edited]), remotes: [], stashCount: 0, operation: nil)
        XCTAssertNil(CommandRules.discardAll(both))
        XCTAssertEqual(both.unstagedCount, 2)
    }

    func testOperationCommandsNeedARunningOperationAndContinueNeedsResolvedConflicts() {
        XCTAssertEqual(CommandRules.continueOperation(clean), .noOperation)
        XCTAssertEqual(CommandRules.abortOperation(clean), .noOperation)
        var state = clean
        state.operation = .cherryPick
        state.conflictCount = 2
        XCTAssertEqual(CommandRules.continueOperation(state), .conflicts)
        XCTAssertNil(CommandRules.abortOperation(state))
        XCTAssertEqual(CommandRules.rebaseInteractive(state), .operationInProgress(.cherryPick))
        XCTAssertEqual(CommandRules.checkout(state), .operationInProgress(.cherryPick))
    }

    func testStashPopAndCopyCommands() {
        XCTAssertEqual(CommandRules.pop(clean), .noStash)
        var state = clean
        state.stashCount = 1
        XCTAssertNil(CommandRules.pop(state))
        state.branch = nil
        XCTAssertEqual(CommandRules.copyBranchName(state), .detachedHead)
        XCTAssertNil(CommandRules.copyHead(state))
    }
}
