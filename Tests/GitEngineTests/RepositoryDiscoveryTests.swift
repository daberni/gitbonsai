import Foundation
import XCTest
@testable import GitEngine

final class RepositoryDiscoveryTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-discovery-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("code", isDirectory: true)
        outside = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    @discardableResult
    private func repository(_ relativePath: String, in base: URL? = nil) throws -> FixtureRepo {
        let fixture = try FixtureRepo(at: (base ?? root).appendingPathComponent(relativePath, isDirectory: true))
        try fixture.commit("initial")
        return fixture
    }

    private func relativePaths(_ repositories: [DiscoveredRepository]) -> [String] {
        let prefix = canonical(root.path) + "/"
        return repositories.map { $0.path.hasPrefix(prefix) ? String($0.path.dropFirst(prefix.count)) : $0.path }
    }

    func testFindsRepositoriesAndSkipsDependencyAndHiddenFolders() throws {
        try repository("alpha")
        try repository("group/beta")
        for skipped in ["node_modules/gamma", ".hidden/delta", ".build/epsilon", "build/zeta", "DerivedData/eta", "Pods/theta", "vendor/iota"] {
            try repository(skipped)
        }

        let found = RepositoryDiscovery.scan(root.path)

        XCTAssertEqual(relativePaths(found), ["alpha", "group/beta"])
        XCTAssertEqual(found.map(\.branch), ["main", "main"])
    }

    func testDoesNotDescendIntoARepository() throws {
        let parent = try repository("parent")
        try repository("parent/nested")
        let library = try repository("library", in: outside)
        try parent.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "modules/library")

        let found = RepositoryDiscovery.scan(root.path)

        XCTAssertEqual(relativePaths(found), ["parent"])
        XCTAssertEqual(found.first?.worktrees, [])
    }

    func testLinkedWorktreesBelongToTheirMainRepository() throws {
        let main = try repository("main")
        let inside = root.appendingPathComponent("main-feature").path
        let elsewhere = outside.appendingPathComponent("main-detached").path
        try main.git("worktree", "add", "-q", "-b", "feature", inside)
        try main.git("worktree", "add", "-q", "--detach", elsewhere)
        let head = try main.git("rev-parse", "--short=7", "HEAD")

        let found = RepositoryDiscovery.scan(root.path)

        XCTAssertEqual(relativePaths(found), ["main"])
        let worktrees = try XCTUnwrap(found.first?.worktrees)
        XCTAssertEqual(worktrees.map { canonical($0.path) }, [canonical(elsewhere), canonical(inside)].sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(Set(worktrees.compactMap(\.branch)), ["feature", head])
    }

    func testLinkedWorktreeOfARepositoryOutsideStandsAlone() throws {
        let main = try repository("project", in: outside)
        let worktree = root.appendingPathComponent("project-review").path
        try main.git("worktree", "add", "-q", "-b", "review", worktree)

        let found = RepositoryDiscovery.scan(root.path)

        XCTAssertEqual(relativePaths(found), ["project-review"])
        XCTAssertEqual(found.first?.isLinked, true)
        XCTAssertEqual(found.first?.branch, "review")
    }

    func testDepthLimitCountsFolderLevelsBelowTheRoot() throws {
        try repository("a/b/c/d/e/at-six")
        try repository("a/b/c/d/e/f/at-seven")

        XCTAssertEqual(relativePaths(RepositoryDiscovery.scan(root.path)), ["a/b/c/d/e/at-six"])
        XCTAssertEqual(relativePaths(RepositoryDiscovery.scan(root.path, depth: 7)), ["a/b/c/d/e/at-six", "a/b/c/d/e/f/at-seven"])
    }

    func testRootThatIsARepositoryIsFound() throws {
        let fixture = try repository("")
        try fixture.git("checkout", "-q", "-b", "topic")

        let found = RepositoryDiscovery.scan(fixture.path)

        XCTAssertEqual(found.map(\.branch), ["topic"])
    }

    private func canonical(_ path: String) -> String {
        RepositoryDiscovery.canonical(path)
    }
}
