import Foundation
import XCTest
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
    }
}
