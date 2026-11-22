import XCTest
@testable import GitEngine

final class RemoteURLsTests: XCTestCase {
    func testRemotesInConfigurationOrderAndTheUpstreamRemote() async throws {
        let repo = try FixtureRepo(name: "remote-urls")
        defer { repo.remove() }
        try repo.commit("first")
        try repo.git("remote", "add", "upstream", "https://github.com/owner/project.git")
        try repo.git("remote", "add", "my.fork", "git@github.com:me/project.git")
        try repo.git("remote", "set-url", "--add", "my.fork", "git@example.com:mirror.git")
        try repo.git("config", "branch.main.remote", "my.fork")
        try repo.git("config", "branch.main.merge", "refs/heads/main")

        let urls = try await repo.repository.remoteURLs()
        XCTAssertEqual(urls.remotes, [.init(name: "upstream", url: "https://github.com/owner/project.git"), .init(name: "my.fork", url: "git@github.com:me/project.git")])
        XCTAssertEqual(urls.upstreamRemote, "my.fork")
    }

    func testNoRemotesOnADetachedHead() async throws {
        let repo = try FixtureRepo(name: "remote-urls-none")
        defer { repo.remove() }
        try repo.commit("first")
        try repo.git("switch", "--detach", "-q")

        let urls = try await repo.repository.remoteURLs()
        XCTAssertEqual(urls, RemoteURLs(remotes: [], upstreamRemote: nil))
    }
}
