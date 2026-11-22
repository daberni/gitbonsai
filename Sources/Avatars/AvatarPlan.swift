import CryptoKit
import Foundation

/// Which services may learn about an author.
public enum AvatarSources: String, Sendable, CaseIterable {
    /// Only the host of the repository's remote, which already has the repository.
    case remoteHost
    /// The remote host first, then Gravatar with the SHA-256 hash of the address.
    case remoteHostAndGravatar
}

/// One way to find an author's avatar. The disk cache keeps its outcome under `cacheKey`.
public struct AvatarStep: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A picture at a known address; 404 means there is none.
        case image(URL)
        /// GitHub's commit list of `repository` (`owner/name`) from `commit` on, which names the account behind each author and committer address.
        case gitHubCommits(repository: String, commit: String, email: String, pixels: Int)
        /// GitLab's `/api/v4/avatar?email=`, answering with the picture's address.
        case gitLabLookup(URL)
    }

    public let kind: Kind
    public let cacheKey: String
}

/// The steps that find one author's avatar, in order. Pure, so the choice of services is testable without a network.
public enum AvatarPlan {
    /// `commit` is a commit that has `email` as author or committer.
    public static func steps(email: String, commit: String, service: AvatarService, sources: AvatarSources, pixels: Int) -> [AvatarStep] {
        guard let address = normalized(email) else { return [] }
        var steps: [AvatarStep] = []
        switch service {
        case .gitHub(let repository):
            let key = "github|\(address)|\(pixels)"
            if let noreply = GitHubNoreply(email: address) {
                steps.append(AvatarStep(kind: .image(noreply.avatarURL(pixels: pixels)), cacheKey: key))
            } else if let repository {
                steps.append(AvatarStep(kind: .gitHubCommits(repository: repository, commit: commit, email: address, pixels: pixels), cacheKey: key))
            }
        case .gitLab(let base):
            var components = URLComponents(url: base.appendingPathComponent("api/v4/avatar"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "email", value: address), URLQueryItem(name: "size", value: "\(pixels)")]
            if let url = components?.url { steps.append(AvatarStep(kind: .gitLabLookup(url), cacheKey: "gitlab:\(base.host ?? "")|\(address)|\(pixels)")) }
        case .none:
            break
        }
        if sources == .remoteHostAndGravatar, let url = URL(string: "https://gravatar.com/avatar/\(gravatarHash(address))?s=\(pixels)&d=404") {
            steps.append(AvatarStep(kind: .image(url), cacheKey: "gravatar|\(address)|\(pixels)"))
        }
        return steps
    }

    /// Trimmed and lower-cased, as Gravatar and the lookups expect; nil for something that is no address.
    public static func normalized(_ email: String) -> String? {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = address.firstIndex(of: "@"), at != address.startIndex, address.index(after: at) != address.endIndex else { return nil }
        return address
    }

    static func gravatarHash(_ address: String) -> String {
        SHA256.hash(data: Data(address.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a picture address belongs to Gravatar, whose default image a host hands out for addresses without their own picture.
    static func isGravatar(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "gravatar.com" || host.hasSuffix(".gravatar.com")
    }
}

/// GitHub's private commit address: `<id>+<login>@users.noreply.github.com`, or `<login>@…` for accounts older than July 2017.
public struct GitHubNoreply: Sendable, Equatable {
    public let id: Int?
    public let login: String

    static let domain = "@users.noreply.github.com"

    public init?(email: String) {
        let address = email.lowercased()
        guard address.hasSuffix(Self.domain) else { return nil }
        let local = address.dropLast(Self.domain.count)
        if let plus = local.firstIndex(of: "+") {
            guard let id = Int(local[..<plus]) else { return nil }
            self.id = id
            login = String(local[local.index(after: plus)...])
        } else {
            id = nil
            login = String(local)
        }
        // Apps commit as `<id>+<name>[bot]`.
        let name = login.hasSuffix("[bot]") && id != nil ? login.dropLast(5) : Substring(login)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
    }

    /// By id where the address has one, since a login can be renamed; otherwise the profile picture redirect of the login.
    public func avatarURL(pixels: Int) -> URL {
        if let id { return URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=\(pixels)&v=4")! }
        return URL(string: "https://github.com/\(login).png?size=\(pixels)")!
    }
}
