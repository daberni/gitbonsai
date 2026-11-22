import XCTest
@testable import GitEngine

final class RepositoryRootTests: XCTestCase {
    func testSubfolderResolvesToRootAndPlainFolderThrows() async throws {
        let fixture = try FixtureRepo(name: "bonsai ü")
        defer { fixture.remove() }
        try fixture.write("nested/deep ü/file.txt", "x\n")
        let expected = URL(fileURLWithPath: fixture.path).resolvingSymlinksInPath().path

        let location = try await Repository.location(containing: fixture.path + "/nested/deep ü")
        XCTAssertEqual(URL(fileURLWithPath: location.root).resolvingSymlinksInPath().path, expected)
        XCTAssertEqual(location.name, fixture.url.lastPathComponent)

        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        do {
            _ = try await Repository.location(containing: plain.path)
            XCTFail("expected GitError for a folder outside any repository")
        } catch is GitError {}
    }

    /// A tab on a linked worktree is named after the repository, not after the worktree's folder.
    func testLinkedWorktreeIsNamedAfterItsRepository() async throws {
        let fixture = try FixtureRepo(name: "main")
        defer { fixture.remove() }
        let first = try fixture.commit("first")
        let linked = fixture.url.deletingLastPathComponent().appendingPathComponent("gitbonsai-linked-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: linked) }
        try fixture.git("worktree", "add", "-q", "--detach", linked, first)

        let location = try await Repository.location(containing: linked)
        XCTAssertEqual(URL(fileURLWithPath: location.root).resolvingSymlinksInPath().path, URL(fileURLWithPath: linked).resolvingSymlinksInPath().path)
        XCTAssertEqual(location.name, fixture.url.lastPathComponent)
    }

    /// git keeps a submodule's repository under the superproject's `.git/modules`.
    func testSubmoduleIsNamedByItsOwnDirectory() {
        let location = Repository.parseLocation(Data("/work/app/vendor/tool\n/work/app/.git/modules/vendor/tool\n".utf8))
        XCTAssertEqual(location?.name, "tool")
        XCTAssertNil(Repository.parseLocation(Data("".utf8)))
    }
}
