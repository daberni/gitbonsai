import XCTest
@testable import GitEngine

final class RepositoryRootTests: XCTestCase {
    func testSubfolderResolvesToRootAndPlainFolderThrows() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.write("nested/deep ü/file.txt", "x\n")
        let expected = URL(fileURLWithPath: fixture.path).resolvingSymlinksInPath().path

        let root = try await Repository.root(containing: fixture.path + "/nested/deep ü")
        XCTAssertEqual(URL(fileURLWithPath: root).resolvingSymlinksInPath().path, expected)

        let plain = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        do {
            _ = try await Repository.root(containing: plain.path)
            XCTFail("expected GitError for a folder outside any repository")
        } catch is GitError {}
    }
}
