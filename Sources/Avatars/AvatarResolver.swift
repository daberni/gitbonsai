import Foundation

/// Performs one HTTP GET. Injected so tests never reach the network.
public protocol AvatarFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// The network, without cookies, credentials or the shared URL cache: the disk cache is the only memory, and nothing the user signed in to goes along.
public struct URLSessionAvatarFetcher: AvatarFetching {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// Runs the steps of `AvatarPlan` against the disk cache and the network: one lookup per cache key at a time, a few requests at once, and no GitHub API calls while its rate limit is used up.
///
/// GitHub's signed-out API only shows public repositories. In a private one every listing answers 404, so authors with their own address get no GitHub avatar (noreply addresses still do, they name the account);
/// in a public one an address maps to an account only when its owner added it to their GitHub account. Both outcomes are remembered on disk for the miss lifetime and tried again afterwards; avatars from private repositories need a signed-in connection to the host.
public actor AvatarResolver {
    /// What one step found. Only `image` and `missing` are cached; `unavailable` (offline, rate limit, server error) is tried again later.
    enum Outcome: Sendable, Equatable {
        case image(Data)
        case missing
        case unavailable
    }

    private let cache: AvatarDiskCache?
    private let fetcher: AvatarFetching
    private let now: @Sendable () -> Date
    private let maxConcurrent: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    /// Accounts GitHub's commit lists named, repositories it does not show and the rate limit's reset, read from and written to the disk cache.
    private var gitHub: GitHubLookupState
    /// Commits GitHub does not have, such as unpushed ones, so no listing starts there again this run.
    private var unknownCommits: Set<String> = []
    private var gitHubListings: [String: Task<Bool, Never>] = [:]
    /// Raised by `discardAll`, so lookups that were running then do not write their results back.
    private var generation = 0

    public init(cache: AvatarDiskCache?, fetcher: AvatarFetching, maxConcurrent: Int = 4, now: @escaping @Sendable () -> Date = Date.init) {
        self.cache = cache
        self.fetcher = fetcher
        self.maxConcurrent = maxConcurrent
        self.now = now
        gitHub = cache?.readGitHubState(now: now()) ?? GitHubLookupState()
    }

    /// Expired entries and the oldest beyond the size limit leave the disk cache.
    public func sweepCache() {
        cache?.sweep(now: now())
    }

    /// Deletes the disk cache and forgets the accounts GitHub named; lookups still running keep their results to themselves.
    public func discardAll() {
        generation += 1
        gitHub = GitHubLookupState()
        cache?.removeAll()
    }

    /// The picture's bytes from the first step that has one; nil when none has, or none could be reached now.
    /// A found picture is also stored under `personKey` (`AvatarPlan.personKey`), where every repository finds it.
    public func image(for steps: [AvatarStep], personKey: String? = nil) async -> Data? {
        let started = generation
        for step in steps {
            guard case .image(let data) = await outcome(of: step) else { continue }
            if let personKey, generation == started { cache?.write(.image(data), for: personKey, now: now()) }
            return data
        }
        return nil
    }

    func outcome(of step: AvatarStep) async -> Outcome {
        if let entry = cache?.read(step.cacheKey, now: now()) {
            switch entry {
            case .image(let data): return .image(data)
            case .missing: return .missing
            }
        }
        if let task = inFlight[step.cacheKey] { return await task.value }
        let started = generation
        let task = Task { await self.lookUp(step) }
        inFlight[step.cacheKey] = task
        let outcome = await task.value
        inFlight[step.cacheKey] = nil
        guard generation == started else { return outcome }
        switch outcome {
        case .image(let data): cache?.write(.image(data), for: step.cacheKey, now: now())
        case .missing: cache?.write(.missing, for: step.cacheKey, now: now())
        case .unavailable: break
        }
        return outcome
    }

    private func lookUp(_ step: AvatarStep) async -> Outcome {
        switch step.kind {
        case .image(let url):
            return await download(url)
        case .gitHubCommits(let repository, let commit, let email, let pixels):
            return await gitHub(repository: repository, commit: commit, email: email, pixels: pixels)
        case .gitLabLookup(let url):
            return await gitLab(url)
        }
    }

    private func download(_ url: URL) async -> Outcome {
        guard let (data, response) = await get(url) else { return .unavailable }
        switch response.statusCode {
        case 200 where !data.isEmpty: return .image(data)
        case 404, 410: return .missing
        default: return .unavailable
        }
    }

    /// Looks the address up in what GitHub's commit lists have named so far; otherwise lists the 100 commits from `commit` on, one listing per repository at a time.
    /// A screenful of history from one author's commit usually holds every other author on it, so one request answers most of them.
    private func gitHub(repository: String, commit: String, email: String, pixels: Int) async -> Outcome {
        var listedOwn = false
        while true {
            if let known = gitHub.accounts[GitHubLookupState.key(email)] {
                guard let id = known.id else { return .missing }
                return await download(URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=\(pixels)&v=4")!)
            }
            if let listing = gitHubListings[repository] {
                _ = await listing.value
                continue
            }
            // GitHub's commits mention every address of theirs, so one missing after its own listing has no account.
            if listedOwn { return .missing }
            // The listing unregisters itself before anyone waiting on it resumes, so a waiter never finds the finished listing again.
            let task = Task {
                let listed = await self.listGitHubCommits(repository: repository, from: commit)
                self.gitHubListings[repository] = nil
                return listed
            }
            gitHubListings[repository] = task
            guard await task.value else { return .unavailable }
            listedOwn = true
        }
    }

    /// Records the accounts of the commit list's addresses. False when GitHub could not answer, rate-limited it, or does not know the commit.
    /// A listing still out when `discardAll` ran keeps its accounts to itself.
    private func listGitHubCommits(repository: String, from commit: String) async -> Bool {
        let started = generation
        if let blocked = gitHub.blockedUntil, blocked > now() { return false }
        guard gitHub.unreachableRepositories[GitHubLookupState.key(repository)] == nil, !unknownCommits.contains(commit) else { return false }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/commits?sha=\(commit)&per_page=100") else { return false }
        guard let (data, response) = await get(url, headers: Self.gitHubHeaders) else { return false }
        switch response.statusCode {
        case 200:
            guard generation == started else { return true }
            let seen = now()
            for (email, id) in Self.gitHubAccounts(in: data) {
                let key = GitHubLookupState.key(email)
                guard gitHub.accounts[key]?.id == nil || id != nil else { continue }
                gitHub.accounts[key] = GitHubLookupState.Account(id: id, seen: seen)
            }
            saveGitHubState()
            return true
        case 403, 429:
            gitHub.blockedUntil = Self.rateLimitReset(response, now: now()) ?? now().addingTimeInterval(3600)
            if generation == started { saveGitHubState() }
            return false
        case 404, 422:
            // Either the commit was never pushed or the repository is not public; one look at the repository tells which.
            unknownCommits.insert(commit)
            if let probe = URL(string: "https://api.github.com/repos/\(repository)"), let (_, answer) = await get(probe, headers: Self.gitHubHeaders), answer.statusCode == 404, generation == started {
                gitHub.unreachableRepositories[GitHubLookupState.key(repository)] = now()
                saveGitHubState()
            }
            return false
        default:
            return false
        }
    }

    private func saveGitHubState() {
        cache?.writeGitHubState(gitHub)
    }

    private static let gitHubHeaders = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]

    private func gitLab(_ url: URL) async -> Outcome {
        guard let (data, response) = await get(url, headers: ["Accept": "application/json"]) else { return .unavailable }
        guard response.statusCode == 200 else { return response.statusCode == 404 ? .missing : .unavailable }
        guard let picture = Self.gitLabAvatarURL(data, host: url.host) else { return .missing }
        return await download(picture)
    }

    private func get(_ url: URL, headers: [String: String] = [:]) async -> (Data, HTTPURLResponse)? {
        await acquire()
        defer { release() }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("GitBonsai", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return try? await fetcher.fetch(request)
    }

    private func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    /// Hands the slot straight to the next waiter, so `running` stays counted.
    private func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
    }

    // MARK: Responses

    /// Author and committer address of each listed commit with the id of the GitHub account behind it, or nil when there is none.
    static func gitHubAccounts(in data: Data) -> [(email: String, id: Int?)] {
        guard let commits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        var accounts: [(email: String, id: Int?)] = []
        for entry in commits {
            let commit = entry["commit"] as? [String: Any]
            for role in ["author", "committer"] {
                guard let person = commit?[role] as? [String: Any], let email = (person["email"] as? String).flatMap(AvatarPlan.normalized) else { continue }
                accounts.append((email, (entry[role] as? [String: Any])?["id"] as? Int))
            }
        }
        return accounts
    }

    /// The uploaded picture GitLab names. Gravatar addresses and the default picture count as none: whether Gravatar may be asked is the user's choice, and is a step of its own.
    static func gitLabAvatarURL(_ data: Data, host: String?) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["avatar_url"] as? String, let url = URL(string: text) else { return nil }
        guard !AvatarPlan.isGravatar(url), !url.path.contains("no_avatar") else { return nil }
        guard let host, url.host?.lowercased() == host.lowercased() else { return nil }
        return url
    }

    static func rateLimitReset(_ response: HTTPURLResponse, now: Date) -> Date? {
        if let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) { return now.addingTimeInterval(retry) }
        return response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }
}
