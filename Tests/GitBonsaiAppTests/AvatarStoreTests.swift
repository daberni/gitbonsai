import AppKit
import Avatars
import XCTest
import GitEngine
@testable import GitBonsaiApp

/// "Initials only" keeps author addresses off the network; "Pictures" asks the remote's host.
@MainActor
final class AvatarStoreTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func temporaryFolder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-avatarstore-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    /// A repository whose origin is on GitHub, so "Pictures" has a service to ask.
    private func gitHubRepository() throws -> Repository {
        let folder = temporaryFolder()
        for arguments in [["init", "-q"], ["remote", "add", "origin", "https://github.com/example/project.git"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", folder.path] + arguments
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        return Repository(path: folder.path)
    }

    /// Asks for the avatar until the store had time to resolve the remote and start a lookup.
    private func ask(_ store: AvatarStore, in repository: Repository, until done: () -> Bool) async {
        for _ in 0..<100 {
            _ = store.image(email: "ada@example.com", commit: String(repeating: "a", count: 40), in: repository)
            if done() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testInitialsOnlyMakesNoRequest() async throws {
        let repository = try gitHubRepository()
        let fetcher = RecordingFetcher()
        let store = AvatarStore(cacheDirectory: temporaryFolder(), fetcher: fetcher) { .initialsOnly }
        XCTAssertFalse(store.showsPictures)
        await ask(store, in: repository) { false }
        XCTAssertEqual(fetcher.count, 0)
    }

    /// The same setup with pictures from the remote host does reach the fake transport, so the test above cannot pass for another reason.
    func testPicturesAsksTheRemoteHost() async throws {
        let repository = try gitHubRepository()
        let fetcher = RecordingFetcher()
        let store = AvatarStore(cacheDirectory: temporaryFolder(), fetcher: fetcher) { .remoteHost }
        await ask(store, in: repository) { fetcher.count > 0 }
        XCTAssertGreaterThan(fetcher.count, 0)
    }
}

private final class RecordingFetcher: AvatarFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0

    var count: Int { lock.withLock { requests } }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests += 1 }
        return (Data(), HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
    }
}
