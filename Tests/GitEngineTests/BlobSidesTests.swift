import XCTest
@testable import GitEngine

/// Reading both sides of a changed binary file, as the image diff does, for every diff source.
final class BlobSidesTests: XCTestCase {
    private let first = Data([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01, 0x02])
    private let second = Data([0x89, 0x50, 0x4e, 0x47, 0x00, 0x03, 0x04, 0x05])
    private let third = Data([0x89, 0x50, 0x4e, 0x47, 0x00, 0x06])

    private func write(_ data: Data, to name: String, in fixture: FixtureRepo) throws {
        try data.write(to: fixture.url.appendingPathComponent(name))
    }

    private func read(_ location: BlobLocation?, in repository: Repository) async throws -> Data? {
        guard let location else { return nil }
        return try await repository.blobData(at: location)
    }

    func testCommitStagedAndUnstagedSides() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try write(first, to: "logo.png", in: fixture)
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "add")
        try write(second, to: "logo.png", in: fixture)
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "change")
        try write(third, to: "logo.png", in: fixture)
        try fixture.git("add", "-A")
        try write(first, to: "logo.png", in: fixture)
        let repository = fixture.repository

        let history = try await repository.collectLog()
        let committed = try await XCTUnwrapAsync(await repository.diff(of: "logo.png", in: .commit(history[0])))
        XCTAssertTrue(committed.isBinary)
        let commitSides = repository.blobSides(of: committed, in: .commit(history[0]))
        let commitOld = try await read(commitSides.old, in: repository)
        let commitNew = try await read(commitSides.new, in: repository)
        XCTAssertEqual(commitOld, first)
        XCTAssertEqual(commitNew, second)

        let staged = try await XCTUnwrapAsync(await repository.diff(of: "logo.png", in: .staged))
        let stagedSides = repository.blobSides(of: staged, in: .staged)
        let stagedOld = try await read(stagedSides.old, in: repository)
        let stagedNew = try await read(stagedSides.new, in: repository)
        XCTAssertEqual(stagedOld, second)
        XCTAssertEqual(stagedNew, third)

        let unstaged = try await XCTUnwrapAsync(await repository.diff(of: "logo.png", in: .unstaged))
        let unstagedSides = repository.blobSides(of: unstaged, in: .unstaged)
        XCTAssertEqual(unstagedSides.new, .workingTree("logo.png"))
        let unstagedOld = try await read(unstagedSides.old, in: repository)
        let unstagedNew = try await read(unstagedSides.new, in: repository)
        XCTAssertEqual(unstagedOld, third)
        XCTAssertEqual(unstagedNew, first)
        let size = await repository.blobSize(at: try XCTUnwrap(unstagedSides.old))
        XCTAssertEqual(size, third.count)
    }

    func testAddedDeletedUntrackedAndRenamedHaveOnlyTheirSides() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try write(first, to: "old.png", in: fixture)
        try write(second, to: "gone.png", in: fixture)
        try fixture.git("add", "-A")
        try fixture.git("commit", "-q", "-m", "add")
        try fixture.git("mv", "old.png", "new.png")
        try fixture.git("rm", "-q", "gone.png")
        try fixture.git("commit", "-q", "-m", "rename and delete")
        try write(third, to: "fresh.png", in: fixture)
        let repository = fixture.repository
        let history = try await repository.collectLog()

        let added = try await XCTUnwrapAsync(await repository.diff(of: "old.png", in: .commit(history[1])))
        let addedSides = repository.blobSides(of: added, in: .commit(history[1]))
        XCTAssertNil(addedSides.old)
        let addedNew = try await read(addedSides.new, in: repository)
        XCTAssertEqual(addedNew, first)

        let deleted = try await XCTUnwrapAsync(await repository.diff(of: "gone.png", in: .commit(history[0])))
        let deletedSides = repository.blobSides(of: deleted, in: .commit(history[0]))
        XCTAssertNil(deletedSides.new)
        let deletedOld = try await read(deletedSides.old, in: repository)
        XCTAssertEqual(deletedOld, second)

        let renamed = try await XCTUnwrapAsync(await repository.diff(of: "new.png", originalPath: "old.png", in: .commit(history[0])))
        let renamedSides = repository.blobSides(of: renamed, in: .commit(history[0]))
        let renamedOld = try await read(renamedSides.old, in: repository)
        let renamedNew = try await read(renamedSides.new, in: repository)
        XCTAssertEqual(renamedOld, first)
        XCTAssertEqual(renamedNew, first)

        let untracked = try await XCTUnwrapAsync(await repository.diff(of: "fresh.png", in: .untracked))
        let untrackedSides = repository.blobSides(of: untracked, in: .untracked)
        XCTAssertNil(untrackedSides.old)
        let untrackedNew = try await read(untrackedSides.new, in: repository)
        XCTAssertEqual(untrackedNew, third)
    }

    /// Without git-lfs installed the pointer is what the repository holds; its diff is text, and reading the side yields the pointer, not an image.
    func testLFSPointerReadsAsPointerText() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let pointer = "version https://git-lfs.github.com/spec/v1\noid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393\nsize 12345\n"
        try fixture.commit("lfs", file: "photo.png", contents: pointer)
        let repository = fixture.repository
        let history = try await repository.collectLog()

        let diff = try await XCTUnwrapAsync(await repository.diff(of: "photo.png", in: .commit(history[0])))
        XCTAssertFalse(diff.isBinary)
        let data = try await read(repository.blobSides(of: diff, in: .commit(history[0])).new, in: repository)
        let parsed = try XCTUnwrap(LFSPointer(try XCTUnwrap(data)))
        XCTAssertEqual(parsed.size, 12345)
        XCTAssertEqual(parsed.oid, "sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393")
        XCTAssertNil(LFSPointer(first))
    }
}
