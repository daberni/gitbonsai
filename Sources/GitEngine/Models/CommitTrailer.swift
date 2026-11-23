import Foundation

/// One trailer of a commit message, such as `Co-authored-by: Ada <ada@example.com>`, as git's trailer parser reads it.
public struct CommitTrailer: Sendable, Hashable {
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    public static let coAuthorKey = "Co-authored-by"
    public static let signOffKey = "Signed-off-by"

    /// Keys compare case-insensitively, as git and GitHub treat them.
    public var isCoAuthor: Bool { key.caseInsensitiveCompare(Self.coAuthorKey) == .orderedSame }

    /// Name and email of a `Name <email>` value; the whole value as name when it has no address.
    public var person: (name: String, email: String) {
        guard let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close else { return (value, "") }
        let name = value[..<open].trimmingCharacters(in: .whitespaces)
        return (name, String(value[value.index(after: open)..<close]))
    }

    /// The text the commit form writes: `Key: value`.
    public var line: String { "\(key): \(value)" }

    /// `body` without its trailer block: trailing lines that start with one of the trailers' keys, their folded continuations and the blank lines before them.
    public static func body(_ body: String, without trailers: [CommitTrailer]) -> String {
        guard !trailers.isEmpty else { return body }
        let keys = Set(trailers.map { $0.key.lowercased() })
        var lines = body.components(separatedBy: "\n")
        while let last = lines.last {
            let isBlank = last.trimmingCharacters(in: .whitespaces).isEmpty
            let isContinuation = last.first == " " || last.first == "\t"
            let key = last.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard isBlank || isContinuation || key.map(keys.contains) == true else { break }
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }
}

/// Reads the `Key: value` lines of `git interpret-trailers --parse` and of the log's `%(trailers:only,unfold)`, which use the same parser.
public enum TrailerParser {
    public static func parse(_ output: String) -> [CommitTrailer] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return key.isEmpty ? nil : CommitTrailer(key: key, value: value)
        }
    }
}

/// A person who authored commits in the repository, as `git shortlog -sne` lists them, most commits first.
public struct KnownAuthor: Sendable, Hashable {
    public let name: String
    public let email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// `Name <email>`, the value of a co-author trailer.
    public var identity: String { "\(name) <\(email)>" }

    /// Parses lines such as `    12\tAda Lovelace <ada@example.com>`.
    public static func parseShortlog(_ output: String) -> [KnownAuthor] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let trailer = CommitTrailer(key: CommitTrailer.coAuthorKey, value: String(line[line.index(after: tab)...]))
            let person = trailer.person
            return person.email.isEmpty ? nil : KnownAuthor(name: person.name, email: person.email)
        }
    }
}
