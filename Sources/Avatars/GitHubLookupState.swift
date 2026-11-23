import Foundation

/// What GitHub's signed-out API told about accounts and repositories, kept next to the pictures so a launch does not ask again.
///
/// Addresses and repositories are stored as SHA-256 hashes, like the picture file names. An account stays as long as a picture, a known absence as long as a miss; the rate limit's reset time is kept until it passed.
public struct GitHubLookupState: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        /// nil when GitHub's commits name the address but no account behind it.
        public var id: Int?
        public var seen: Date
    }

    /// Per hashed lower-cased address.
    public var accounts: [String: Account] = [:]
    /// Hashed `owner/name` of repositories signed-out GitHub does not show, such as private ones, with when that was found.
    public var unreachableRepositories: [String: Date] = [:]
    public var blockedUntil: Date?

    public init() {}

    /// Drops what outlived its lifetime, and dates in the future beyond clock skew.
    mutating func expire(now: Date, accountLifetime: TimeInterval, missingLifetime: TimeInterval) {
        func fresh(_ date: Date, _ lifetime: TimeInterval) -> Bool {
            now.timeIntervalSince(date) < lifetime && now >= date.addingTimeInterval(-60)
        }
        accounts = accounts.filter { fresh($0.value.seen, $0.value.id == nil ? missingLifetime : accountLifetime) }
        unreachableRepositories = unreachableRepositories.filter { fresh($0.value, missingLifetime) }
        if let blocked = blockedUntil, blocked <= now { blockedUntil = nil }
    }

    static func key(_ text: String) -> String {
        AvatarPlan.sha256(text)
    }
}

extension AvatarDiskCache {
    /// The GitHub state's file inside the cache folder; `sweep` leaves it alone and `removeAll` deletes it with the folder.
    var gitHubStateFile: URL {
        directory.appendingPathComponent("github-state.json")
    }

    /// The stored state without expired parts; empty when there is none or it cannot be read.
    public func readGitHubState(now: Date) -> GitHubLookupState {
        guard let data = try? Data(contentsOf: gitHubStateFile), var state = try? JSONDecoder().decode(GitHubLookupState.self, from: data) else { return GitHubLookupState() }
        state.expire(now: now, accountLifetime: imageLifetime, missingLifetime: missingLifetime)
        return state
    }

    public func writeGitHubState(_ state: GitHubLookupState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: gitHubStateFile, options: .atomic)
    }
}
