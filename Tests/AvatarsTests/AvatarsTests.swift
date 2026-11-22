import Foundation
import XCTest
@testable import Avatars

final class AvatarServiceTests: XCTestCase {
    func testServiceFromRemoteURLForms() {
        XCTAssertEqual(AvatarService(remoteURL: "https://github.com/apple/swift-argument-parser.git"), .gitHub(repository: "apple/swift-argument-parser"))
        XCTAssertEqual(AvatarService(remoteURL: "git@github.com:apple/swift.git"), .gitHub(repository: "apple/swift"))
        XCTAssertEqual(AvatarService(remoteURL: "ssh://git@ssh.github.com:443/Owner/Repo/"), .gitHub(repository: "Owner/Repo"))
        XCTAssertEqual(AvatarService(remoteURL: "https://user@GitHub.com/o"), .gitHub(repository: nil))
        XCTAssertEqual(AvatarService(remoteURL: "git@gitlab.com:group/sub/project.git"), .gitLab(base: URL(string: "https://gitlab.com")!))
        XCTAssertEqual(AvatarService(remoteURL: "https://gitlab.example.org/team/app"), .gitLab(base: URL(string: "https://gitlab.example.org")!))
        XCTAssertEqual(AvatarService(remoteURL: "git@bitbucket.org:team/app.git"), .none)
        XCTAssertEqual(AvatarService(remoteURL: "https://git.example.com/team/app"), .none)
        XCTAssertEqual(AvatarService(remoteURL: "/Users/me/repos/app.git"), .none)
        XCTAssertEqual(AvatarService(remoteURL: "../app"), .none)
        XCTAssertEqual(AvatarService(remoteURL: "file:///Users/me/app"), .none)
    }

    func testRemotePreferenceUpstreamThenOriginThenFirst() {
        let remotes = [(name: "fork", url: "a"), (name: "origin", url: "b"), (name: "upstream", url: "c")]
        XCTAssertEqual(AvatarService.remoteURL(in: remotes, upstreamRemote: "upstream"), "c")
        XCTAssertEqual(AvatarService.remoteURL(in: remotes, upstreamRemote: nil), "b")
        XCTAssertEqual(AvatarService.remoteURL(in: remotes, upstreamRemote: "gone"), "b")
        XCTAssertEqual(AvatarService.remoteURL(in: [(name: "fork", url: "a"), (name: "z", url: "z")], upstreamRemote: nil), "a")
        XCTAssertNil(AvatarService.remoteURL(in: [], upstreamRemote: nil))
    }
}

final class AvatarPlanTests: XCTestCase {
    func testNoreplyAddresses() {
        let modern = GitHubNoreply(email: "12345+Octo-Cat@users.noreply.github.com")
        XCTAssertEqual(modern?.id, 12345)
        XCTAssertEqual(modern?.login, "octo-cat")
        XCTAssertEqual(modern?.avatarURL(pixels: 56).absoluteString, "https://avatars.githubusercontent.com/u/12345?s=56&v=4")
        let legacy = GitHubNoreply(email: "octocat@users.noreply.github.com")
        XCTAssertNil(legacy?.id)
        XCTAssertEqual(legacy?.avatarURL(pixels: 56).absoluteString, "https://github.com/octocat.png?size=56")
        XCTAssertEqual(GitHubNoreply(email: "49699333+dependabot[bot]@users.noreply.github.com")?.id, 49699333)
        XCTAssertNil(GitHubNoreply(email: "dependabot[bot]@users.noreply.github.com"))
        XCTAssertNil(GitHubNoreply(email: "abc+octocat@users.noreply.github.com"))
        XCTAssertNil(GitHubNoreply(email: "octocat@github.com"))
        XCTAssertNil(GitHubNoreply(email: "a/b@users.noreply.github.com"))
    }

    func testStepsPerServiceAndSources() {
        let sha = String(repeating: "a", count: 40)
        let noreply = AvatarPlan.steps(email: "1+me@users.noreply.github.com", commit: sha, service: .gitHub(repository: "o/r"), sources: .remoteHost, pixels: 56)
        XCTAssertEqual(noreply.map(\.kind), [.image(URL(string: "https://avatars.githubusercontent.com/u/1?s=56&v=4")!)])

        let other = AvatarPlan.steps(email: " Me@Example.com ", commit: sha, service: .gitHub(repository: "o/r"), sources: .remoteHost, pixels: 56)
        XCTAssertEqual(other.map(\.kind), [.gitHubCommits(repository: "o/r", commit: sha, email: "me@example.com", pixels: 56)])
        XCTAssertEqual(other.first?.cacheKey, "github|me@example.com|56")

        let withGravatar = AvatarPlan.steps(email: "me@example.com", commit: sha, service: .gitHub(repository: nil), sources: .remoteHostAndGravatar, pixels: 56)
        // SHA-256 of "me@example.com".
        XCTAssertEqual(withGravatar.map(\.kind), [.image(URL(string: "https://gravatar.com/avatar/\(AvatarPlan.gravatarHash("me@example.com"))?s=56&d=404")!)])
        XCTAssertEqual(AvatarPlan.gravatarHash("me@example.com").count, 64)

        let gitLab = AvatarPlan.steps(email: "me@example.com", commit: sha, service: .gitLab(base: URL(string: "https://gitlab.com")!), sources: .remoteHost, pixels: 48)
        XCTAssertEqual(gitLab.map(\.kind), [.gitLabLookup(URL(string: "https://gitlab.com/api/v4/avatar?email=me@example.com&size=48")!)])

        XCTAssertTrue(AvatarPlan.steps(email: "me@example.com", commit: sha, service: .none, sources: .remoteHost, pixels: 56).isEmpty)
        XCTAssertTrue(AvatarPlan.steps(email: "not an address", commit: sha, service: .gitHub(repository: "o/r"), sources: .remoteHostAndGravatar, pixels: 56).isEmpty)
    }
}

final class AvatarDiskCacheTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-cache-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPicturesAndMissesExpireSeparately() {
        let cache = AvatarDiskCache(directory: directory, imageLifetime: 7 * 86_400, missingLifetime: 3 * 86_400)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        cache.write(.image(Data([1, 2, 3])), for: "found", now: start)
        cache.write(.missing, for: "none", now: start)
        XCTAssertEqual(cache.read("found", now: start.addingTimeInterval(6 * 86_400)), .image(Data([1, 2, 3])))
        XCTAssertEqual(cache.read("none", now: start.addingTimeInterval(2 * 86_400)), .missing)
        XCTAssertNil(cache.read("none", now: start.addingTimeInterval(4 * 86_400)))
        XCTAssertNil(cache.read("found", now: start.addingTimeInterval(8 * 86_400)))
        // Expired entries are gone, not only skipped.
        XCTAssertNil(cache.read("found", now: start))
    }

    func testANewOutcomeReplacesTheOther() {
        let cache = AvatarDiskCache(directory: directory)
        let now = Date()
        cache.write(.missing, for: "key", now: now)
        cache.write(.image(Data([9])), for: "key", now: now)
        XCTAssertEqual(cache.read("key", now: now), .image(Data([9])))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }
}

final class AvatarCacheCleanupTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-cleanup-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    /// Entries never read again still leave once expired, and the folder stays under its limit by dropping the oldest.
    func testSweepRemovesExpiredThenOldestBeyondTheLimit() throws {
        let cache = AvatarDiskCache(directory: directory, imageLifetime: 7 * 86_400, missingLifetime: 3 * 86_400, maxBytes: 250)
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        cache.write(.image(Data(count: 100)), for: "expired picture", now: now.addingTimeInterval(-8 * day))
        cache.write(.missing, for: "expired miss", now: now.addingTimeInterval(-4 * day))
        cache.write(.missing, for: "recent miss", now: now.addingTimeInterval(-1 * day))
        cache.write(.image(Data(count: 100)), for: "oldest", now: now.addingTimeInterval(-6 * day))
        cache.write(.image(Data(count: 100)), for: "middle", now: now.addingTimeInterval(-5 * day))
        cache.write(.image(Data(count: 100)), for: "newest", now: now.addingTimeInterval(-2 * day))
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)
        XCTAssertEqual(try names().count, 7)

        cache.sweep(now: now)

        XCTAssertNil(cache.read("oldest", now: now))
        XCTAssertEqual(cache.read("middle", now: now), .image(Data(count: 100)))
        XCTAssertEqual(cache.read("newest", now: now), .image(Data(count: 100)))
        XCTAssertEqual(cache.read("recent miss", now: now), .missing)
        XCTAssertEqual(try names().count, 4, "expired picture, expired miss and the oldest picture are gone; notes.txt stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    /// Turning avatars off deletes the folder, and a lookup that was still running does not write it back.
    func testDiscardAllDeletesTheCacheAndRunningLookupsDoNotRefillIt() async throws {
        let cache = AvatarDiskCache(directory: directory)
        cache.write(.image(Data([1])), for: "earlier", now: Date())
        let fetcher = FakeFetcher { _ in (200, Data([2]), [:]) }
        let resolver = AvatarResolver(cache: cache, fetcher: fetcher)
        let steps = AvatarPlan.steps(email: "1+me@users.noreply.github.com", commit: "c", service: .gitHub(repository: "o/r"), sources: .remoteHost, pixels: 56)
        let lookup = Task { await resolver.image(for: steps) }
        // The fake fetcher answers after 20 ms; discard while the request is out.
        try await Task.sleep(nanoseconds: 5_000_000)
        await resolver.discardAll()
        let image = await lookup.value
        XCTAssertEqual(image, Data([2]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMemoryCacheDropsTheLeastRecentlyUsed() {
        var cache = AvatarMemoryCache<Int>(capacity: 2)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c")
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.value(for: "a"), 1)
        XCTAssertEqual(cache.value(for: "c"), 3)
    }
}

final class AvatarResolverTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("avatar-resolver-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let sha = String(repeating: "b", count: 40)

    func testConcurrentRequestsForOneAuthorMakeOneRequest() async {
        let fetcher = FakeFetcher { _ in (200, Data([7]), [:]) }
        let resolver = AvatarResolver(cache: AvatarDiskCache(directory: directory), fetcher: fetcher)
        let steps = AvatarPlan.steps(email: "1+me@users.noreply.github.com", commit: sha, service: .gitHub(repository: "o/r"), sources: .remoteHost, pixels: 56)
        let results = await withTaskGroup(of: Data?.self) { group in
            for _ in 0..<8 { group.addTask { await resolver.image(for: steps) } }
            return await group.reduce(into: [Data?]()) { $0.append($1) }
        }
        XCTAssertEqual(results, Array(repeating: Data([7]), count: 8))
        XCTAssertEqual(fetcher.urls.count, 1)
    }

    /// One commit list names the accounts of every author on it; addresses without account are remembered as missing, on disk too.
    func testOneCommitListAnswersSeveralAuthors() async {
        let listing = #"[{"sha":"b","commit":{"author":{"email":"Me@Example.com"},"committer":{"email":"noreply@github.com"}},"author":{"id":42},"committer":{"id":19864447}},{"sha":"c","commit":{"author":{"email":"you@example.com"},"committer":{"email":"you@example.com"}},"author":{"id":7},"committer":{"id":7}},{"sha":"d","commit":{"author":{"email":"nobody@example.com"},"committer":{"email":"you@example.com"}},"author":null,"committer":{"id":7}}]"#
        let fetcher = FakeFetcher { url in
            if url.host == "api.github.com" { return (200, Data(listing.utf8), [:]) }
            return (200, Data(url.path.utf8), [:])
        }
        let cache = AvatarDiskCache(directory: directory)
        let resolver = AvatarResolver(cache: cache, fetcher: fetcher)
        let sha = sha
        let steps: @Sendable (String) -> [AvatarStep] = { email in
            AvatarPlan.steps(email: email, commit: sha, service: .gitHub(repository: "o/r"), sources: .remoteHost, pixels: 56)
        }
        let results = await withTaskGroup(of: (String, Data?).self) { group in
            for email in ["me@example.com", "you@example.com", "nobody@example.com"] { group.addTask { (email, await resolver.image(for: steps(email))) } }
            return await group.reduce(into: [String: Data?]()) { $0[$1.0] = $1.1 }
        }
        XCTAssertEqual(results["me@example.com"], Data("/u/42".utf8))
        XCTAssertEqual(results["you@example.com"], Data("/u/7".utf8))
        XCTAssertEqual(results["nobody@example.com"], .some(nil))
        XCTAssertEqual(fetcher.urls.filter { $0.host == "api.github.com" }.map(\.absoluteString), ["https://api.github.com/repos/o/r/commits?sha=\(sha)&per_page=100"])
        XCTAssertEqual(fetcher.urls.count, 3)

        // A later run answers all three from disk without the network.
        let offline = FakeFetcher { _ in throw URLError(.notConnectedToInternet) }
        let later = AvatarResolver(cache: cache, fetcher: offline)
        let again = await later.image(for: steps("me@example.com"))
        let stillNone = await later.image(for: steps("nobody@example.com"))
        XCTAssertEqual(again, Data("/u/42".utf8))
        XCTAssertNil(stillNone)
        XCTAssertTrue(offline.urls.isEmpty)
    }

    /// Authors waiting on another author's listing resume once it finished, instead of finding the finished listing over and over;
    /// an author missing from it, such as one on a side branch, then lists from their own commit.
    func testManyAuthorsWaitingOnOneListingAllResolve() async {
        let emails = (0..<20).map { "author\($0)@example.com" }
        let listing = "[" + emails.enumerated().map { #"{"commit":{"author":{"email":"\#($1)"},"committer":{"email":"\#($1)"}},"author":{"id":\#($0 + 1)},"committer":{"id":\#($0 + 1)}}"# }.joined(separator: ",") + "]"
        let fetcher = FakeFetcher { url in url.host == "api.github.com" ? (200, Data(listing.utf8), [:]) : (200, Data(url.path.utf8), [:]) }
        let resolver = AvatarResolver(cache: nil, fetcher: fetcher)
        let sha = sha
        let found = await withTaskGroup(of: Int.self) { group in
            for email in emails + ["side@example.com"] {
                group.addTask { await resolver.image(for: AvatarPlan.steps(email: email, commit: sha, service: .gitHub(repository: "o/r"), sources: .remoteHost, pixels: 56)) == nil ? 0 : 1 }
            }
            return await group.reduce(0, +)
        }
        XCTAssertEqual(found, emails.count)
        XCTAssertEqual(fetcher.urls.filter { $0.host == "api.github.com" }.count, 2)
    }

    /// An unpushed commit costs one listing and one look at the repository; a private repository stops all further listings.
    func testUnknownCommitsAndPrivateRepositories() async {
        let fetcher = FakeFetcher { _ in (404, Data(), [:]) }
        let resolver = AvatarResolver(cache: AvatarDiskCache(directory: directory), fetcher: fetcher)
        for (email, commit) in [("a@example.com", "c1"), ("b@example.com", "c1"), ("c@example.com", "c2")] {
            let image = await resolver.image(for: AvatarPlan.steps(email: email, commit: commit, service: .gitHub(repository: "o/private"), sources: .remoteHost, pixels: 56))
            XCTAssertNil(image)
        }
        XCTAssertEqual(fetcher.urls.map(\.path), ["/repos/o/private/commits", "/repos/o/private"])
        // Not stored as missing: signed-out GitHub only could not say.
        XCTAssertNil(AvatarDiskCache(directory: directory).read("github|a@example.com|56", now: Date()))
    }

    func testOfflineIsNotRememberedAsMissing() async {
        let cache = AvatarDiskCache(directory: directory)
        let steps = AvatarPlan.steps(email: "me@example.com", commit: sha, service: .none, sources: .remoteHostAndGravatar, pixels: 56)
        let offline = AvatarResolver(cache: cache, fetcher: FakeFetcher { _ in throw URLError(.notConnectedToInternet) })
        let none = await offline.image(for: steps)
        XCTAssertNil(none)
        let online = AvatarResolver(cache: cache, fetcher: FakeFetcher { _ in (200, Data([5]), [:]) })
        let found = await online.image(for: steps)
        XCTAssertEqual(found, Data([5]))
    }

    func testRateLimitStopsGitHubLookupsButNotGravatar() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fetcher = FakeFetcher { url in
            if url.host == "api.github.com" { return (403, Data(), ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "\(Int(now.timeIntervalSince1970) + 600)"]) }
            return (404, Data(), [:])
        }
        let resolver = AvatarResolver(cache: AvatarDiskCache(directory: directory), fetcher: fetcher, now: { now })
        for email in ["a@example.com", "b@example.com", "c@example.com"] {
            _ = await resolver.image(for: AvatarPlan.steps(email: email, commit: sha, service: .gitHub(repository: "o/r"), sources: .remoteHostAndGravatar, pixels: 56))
        }
        XCTAssertEqual(fetcher.urls.filter { $0.host == "api.github.com" }.count, 1)
        XCTAssertEqual(fetcher.urls.filter { $0.host == "gravatar.com" }.count, 3)
        // Rate-limited lookups were not stored as misses.
        XCTAssertNil(AvatarDiskCache(directory: directory).read("github|b@example.com|56", now: now))
    }

    func testGitLabGravatarFallbackCountsAsNone() async {
        let fetcher = FakeFetcher { url in
            if url.path.hasSuffix("/api/v4/avatar") { return (200, Data(#"{"avatar_url":"https://secure.gravatar.com/avatar/abc?s=56&d=identicon"}"#.utf8), [:]) }
            return (200, Data([3]), [:])
        }
        let resolver = AvatarResolver(cache: nil, fetcher: fetcher)
        let image = await resolver.image(for: AvatarPlan.steps(email: "me@example.com", commit: sha, service: .gitLab(base: URL(string: "https://gitlab.com")!), sources: .remoteHost, pixels: 56))
        XCTAssertNil(image)
        XCTAssertEqual(fetcher.urls.count, 1)
        XCTAssertEqual(AvatarResolver.gitLabAvatarURL(Data(#"{"avatar_url":"https://gitlab.com/uploads/-/system/user/avatar/1/a.png"}"#.utf8), host: "gitlab.com")?.path, "/uploads/-/system/user/avatar/1/a.png")
    }
}

/// Answers from a closure and records every requested URL.
final class FakeFetcher: AvatarFetching, @unchecked Sendable {
    typealias Answer = (status: Int, data: Data, headers: [String: String])
    private let answer: @Sendable (URL) throws -> Answer
    private let lock = NSLock()
    private var requested: [URL] = []

    init(_ answer: @escaping @Sendable (URL) throws -> Answer) {
        self.answer = answer
    }

    var urls: [URL] { lock.withLock { requested } }

    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        lock.withLock { requested.append(url) }
        // Lets concurrent callers overlap, as real requests would.
        try await Task.sleep(nanoseconds: 20_000_000)
        let (status, data, headers) = try answer(url)
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}
