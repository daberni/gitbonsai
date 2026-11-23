import XCTest
@testable import GitEngine

final class CommitGraphTests: XCTestCase {
    private var fixture: FixtureRepo!

    override func setUpWithError() throws {
        fixture = try FixtureRepo()
        _ = try fixture.commit("first")
    }

    override func tearDown() {
        fixture.remove()
    }

    private var graphPath: String { fixture.path + "/.git/objects/info/commit-graph" }

    func testWritesMissingGraphOnce() async {
        let repository = Repository(path: fixture.path)
        let wrote = await repository.writeCommitGraphIfMissing()
        XCTAssertTrue(wrote)
        XCTAssertTrue(FileManager.default.fileExists(atPath: graphPath))
        let wroteAgain = await repository.writeCommitGraphIfMissing()
        XCTAssertFalse(wroteAgain)
    }

    func testRespectsDisabledCommitGraph() async throws {
        try fixture.git("config", "core.commitGraph", "false")
        let wrote = await Repository(path: fixture.path).writeCommitGraphIfMissing()
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: graphPath))
    }

    func testRespectsDisabledGcGraph() async throws {
        try fixture.git("config", "gc.writeCommitGraph", "no")
        let wrote = await Repository(path: fixture.path).writeCommitGraphIfMissing()
        XCTAssertFalse(wrote)
    }

    func testWaitsForAnotherGitOperation() async throws {
        FileManager.default.createFile(atPath: fixture.path + "/.git/index.lock", contents: nil)
        let wrote = await Repository(path: fixture.path).writeCommitGraphIfMissing()
        XCTAssertFalse(wrote)
        XCTAssertFalse(FileManager.default.fileExists(atPath: graphPath))
    }
}
