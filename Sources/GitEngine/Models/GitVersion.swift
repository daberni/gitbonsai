import Foundation

/// A git release number, compared numerically. Vendor suffixes such as "(Apple Git-154)" or ".windows.1" are ignored.
public struct GitVersion: Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    /// The oldest git the app supports; older ones lack options the parsers and actions rely on.
    public static let minimumSupported = GitVersion(major: 2, minor: 38, patch: 0)

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// Parses the output of `git --version`, for example "git version 2.39.5 (Apple Git-154)".
    public init?(versionOutput: String) {
        let prefix = "git version "
        guard let line = versionOutput.split(whereSeparator: \.isNewline).first, line.hasPrefix(prefix) else { return nil }
        let number = line.dropFirst(prefix.count).prefix { !$0.isWhitespace }
        let parts = number.split(separator: ".").prefix(3).map { Int($0) }
        guard parts.count >= 2, let major = parts[0], let minor = parts[1] else { return nil }
        self.init(major: major, minor: minor, patch: parts.count > 2 ? parts[2] ?? 0 : 0)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: GitVersion, rhs: GitVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
