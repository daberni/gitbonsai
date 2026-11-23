import Foundation
import XCTest
import GraphLayout
@testable import GitEngine

final class RefsTests: XCTestCase {
    func testLocalRemoteTagUpstreamAndHead() async throws {
        let remote = try FixtureRepo(name: "remote")
        defer { remote.remove() }
        let remoteFirst = try remote.commit("remote one")
        try remote.commit("remote two")

        let fixture = try FixtureRepo(name: "local")
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("checkout", "-q", "-b", "main", "--track", "origin/main")
        try fixture.git("reset", "-q", "--hard", remoteFirst)
        let local = try fixture.commit("local only", file: "local.txt")
        try fixture.git("tag", "-a", "v1.0", "-m", "release", remoteFirst)
        try fixture.git("tag", "light", local)
        try fixture.git("branch", "feature")

        let refs = try await fixture.repository.refs()
        let byName = Dictionary(uniqueKeysWithValues: refs.map { ($0.fullName, $0) })

        let main = try XCTUnwrap(byName["refs/heads/main"])
        XCTAssertEqual(main.kind, .localBranch)
        XCTAssertEqual(main.name, "main")
        XCTAssertTrue(main.isHead)
        XCTAssertEqual(main.target, local)
        XCTAssertEqual(main.upstream, "origin/main")
        XCTAssertEqual(main.ahead, 1)
        XCTAssertEqual(main.behind, 1)

        let feature = try XCTUnwrap(byName["refs/heads/feature"])
        XCTAssertFalse(feature.isHead)
        XCTAssertNil(feature.upstream)
        XCTAssertNil(feature.ahead)

        let originMain = try XCTUnwrap(byName["refs/remotes/origin/main"])
        XCTAssertEqual(originMain.kind, .remoteBranch(remote: "origin"))
        XCTAssertEqual(originMain.name, "origin/main")

        let annotated = try XCTUnwrap(byName["refs/tags/v1.0"])
        XCTAssertEqual(annotated.kind, .tag)
        XCTAssertEqual(annotated.target, remoteFirst, "annotated tags report the peeled commit")

        let lightweight = try XCTUnwrap(byName["refs/tags/light"])
        XCTAssertEqual(lightweight.target, local)
    }

    func testDetachedHeadMarksNoBranch() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let first = try fixture.commit("one")
        try fixture.commit("two")
        try fixture.git("checkout", "-q", first)

        let refs = try await fixture.repository.refs()

        XCTAssertFalse(refs.contains { $0.isHead })
    }

    func testTrackParsing() {
        XCTAssertEqual(RefsParser.parseTrack("[ahead 3, behind 2]").0, 3)
        XCTAssertEqual(RefsParser.parseTrack("[ahead 3, behind 2]").1, 2)
        XCTAssertEqual(RefsParser.parseTrack("[behind 5]").0, 0)
        XCTAssertEqual(RefsParser.parseTrack("[behind 5]").1, 5)
        XCTAssertNil(RefsParser.parseTrack("[gone]").0)
        XCTAssertNil(RefsParser.parseTrack("").1)
        XCTAssertEqual(RefsParser.parseTrack("[ahead 4]").0, 4)
        XCTAssertEqual(RefsParser.parseTrack("[ahead 4]").1, 0)
    }

    /// The sidebar shows ahead and behind on every local branch from the one `for-each-ref` call, including branches that are not checked out.
    func testAheadAndBehindOfEveryTrackingBranch() async throws {
        let remote = try FixtureRepo(name: "remote")
        defer { remote.remove() }
        let base = try remote.commit("base")
        try remote.git("branch", "feature")
        try remote.commit("remote main")
        let fixture = try FixtureRepo(name: "local")
        defer { fixture.remove() }
        try fixture.git("remote", "add", "origin", remote.path)
        try fixture.git("fetch", "-q", "origin")
        try fixture.git("checkout", "-q", "-b", "main", "--track", "origin/main")
        try fixture.git("branch", "--track", "stale", "origin/main")
        try fixture.git("reset", "-q", "--hard", base)
        try fixture.git("checkout", "-q", "-b", "feature", "--track", "origin/feature")
        try fixture.commit("one", file: "a.txt")
        try fixture.commit("two", file: "b.txt")
        try fixture.git("branch", "--track", "even", "origin/main")

        let refs = Dictionary(uniqueKeysWithValues: try await fixture.repository.refs().map { ($0.name, $0) })

        XCTAssertEqual(refs["main"].map { [$0.ahead, $0.behind] }, [0, 1])
        XCTAssertEqual(refs["feature"].map { [$0.ahead, $0.behind] }, [2, 0])
        XCTAssertEqual(refs["stale"]?.upstream, "origin/main")
        XCTAssertNil(refs["even"]?.ahead, "git reports nothing for a branch even with its upstream")
    }
}

final class RefSelectionTests: XCTestCase {
    var fixture: FixtureRepo!

    override func setUpWithError() throws {
        fixture = try FixtureRepo(name: "ref-selection")
        try fixture.commit("one")
    }

    override func tearDown() {
        fixture.remove()
    }

    /// Tools such as Codex or jj keep snapshots under their own namespaces; they are not branches or tags and get no pill.
    func testToolRefsAreLeftOut() async throws {
        try fixture.git("update-ref", "refs/codex/snapshot", "HEAD")
        try fixture.git("update-ref", "refs/notes/commits", "HEAD")
        try fixture.write("file.txt", "changed\n")
        try fixture.git("stash", "push", "-q")

        let names = try await fixture.repository.refs().map(\.fullName).sorted()
        XCTAssertEqual(names, ["refs/heads/main", "refs/stash"])
    }

    /// Tags of a tree or a blob are no commits; as history tips they were never loaded and made every refresh read the whole log again.
    func testTagsOfTreesAndBlobsAreLeftOutOfRefsTagsAndTheRefreshPlan() async throws {
        let tree = try fixture.git("rev-parse", "HEAD^{tree}")
        let blob = try fixture.git("rev-parse", "HEAD:file.txt")
        try fixture.git("tag", "light-tree", tree)
        try fixture.git("tag", "-a", "annotated-blob", "-m", "blob", blob)
        try fixture.git("tag", "release")
        let repository = fixture.repository

        let refs = try await repository.refs()
        XCTAssertEqual(refs.filter { $0.kind == .tag }.map(\.name), ["release"])
        let tags = try await repository.tags()
        XCTAssertEqual(tags.map(\.name), ["release"])
        let commits = try await repository.collectLog()
        let tips = HistoryRefresh.tips(refs: refs, head: commits.first?.id, stashCommits: [])
        XCTAssertEqual(HistoryRefresh.plan(loaded: commits, tips: tips), .keep(dropping: []))
    }
}

final class SHA256Tests: XCTestCase {
    func testLogRefsAndStatusReadA256BitRepository() async throws {
        let fixture = try FixtureRepo(name: "sha256", objectFormat: "sha256")
        defer { fixture.remove() }
        let first = try fixture.commit("one")
        let second = try fixture.commit("two")
        XCTAssertEqual(second.count, 64)
        let repository = fixture.repository

        let commits = try await repository.collectLog()
        XCTAssertEqual(commits.map(\.id), [second, first])
        XCTAssertEqual(commits.first?.parents, [first])
        let refs = try await repository.refs()
        XCTAssertEqual(refs.first { $0.kind == .localBranch }?.target, second)
        XCTAssertTrue(RefCatalog.looksLikeSHA(second))
    }
}
