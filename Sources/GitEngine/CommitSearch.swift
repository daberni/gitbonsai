import Foundation

/// A case-insensitive text query over loaded commits: subject, body, author name and email, ref names on the commit, and a SHA prefix.
///
/// It reads only values that `git log` already delivered, so a search needs no further git call and can run over a partly loaded history.
public struct CommitSearch: Sendable, Equatable {
    /// The query as typed, without surrounding whitespace.
    public let text: String
    /// Lowercased ASCII bytes of the query; nil when it contains other characters and needs Unicode case folding.
    private let asciiFolded: [UInt8]?
    private let shaPrefix: String?

    /// A SHA prefix needs this many characters; shorter hex words such as "add" or "fe" would match commits whose text does not contain them.
    public static let minimumSHAPrefix = 4

    /// Nil for a query that is empty or only whitespace.
    public init?(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        self.text = text
        let lowered = text.lowercased()
        asciiFolded = lowered.utf8.allSatisfy { $0 < 0x80 } ? Array(lowered.utf8) : nil
        let isHex = lowered.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
        shaPrefix = isHex && lowered.utf8.count >= Self.minimumSHAPrefix ? lowered : nil
    }

    public func matches(_ commit: Commit, refNames: [String] = []) -> Bool {
        if matchesSHA(commit.id) { return true }
        return contains(commit.subject) || contains(commit.authorName) || contains(commit.authorEmail) || refNames.contains(where: contains) || contains(commit.body)
    }

    /// Whether the query is a prefix of `id`, long enough to count as one.
    public func matchesSHA(_ id: String) -> Bool {
        guard let shaPrefix else { return false }
        return id.hasPrefix(shaPrefix)
    }

    /// Positions in `commits` within `range` that match, in ascending order.
    public func matchingIndices(in commits: [Commit], range: Range<Int>, refNames: [String: [String]]) -> [Int] {
        var result: [Int] = []
        for index in range where matches(commits[index], refNames: refNames[commits[index].id] ?? []) {
            result.append(index)
        }
        return result
    }

    /// Every non-overlapping occurrence of the query in `string`, for highlighting what matched.
    public func occurrences(in string: String) -> [NSRange] {
        string.caseInsensitiveOccurrences(of: text)
    }

    /// The ASCII path compares UTF-8 bytes with folded letters, which is an order of magnitude faster than Foundation's case-insensitive search over 100k commits.
    func contains(_ field: String) -> Bool {
        guard let needle = asciiFolded else {
            // Most fields are plain ASCII and cannot hold a query with other characters, which spares Foundation's search for them.
            let isASCII = field.utf8.withContiguousStorageIfAvailable { $0.allSatisfy { $0 < 0x80 } } ?? false
            return !isASCII && field.range(of: text, options: .caseInsensitive) != nil
        }
        let found = field.utf8.withContiguousStorageIfAvailable { haystack in
            needle.withUnsafeBufferPointer { Self.asciiFoldedContains(haystack, $0) }
        }
        return found ?? (field.range(of: text, options: .caseInsensitive) != nil)
    }

    private static func asciiFoldedContains(_ haystack: UnsafeBufferPointer<UInt8>, _ needle: UnsafeBufferPointer<UInt8>) -> Bool {
        let count = needle.count
        guard haystack.count >= count, let base = haystack.baseAddress, let pattern = needle.baseAddress else { return false }
        let first = pattern.pointee
        let last = haystack.count - count
        var start = 0
        while start <= last {
            if fold(base[start]) == first {
                var offset = 1
                while offset < count, fold(base[start + offset]) == pattern[offset] { offset += 1 }
                if offset == count { return true }
            }
            start += 1
        }
        return false
    }

    @inline(__always)
    private static func fold(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5a ? byte | 0x20 : byte
    }
}

extension String {
    /// Every non-overlapping case-insensitive occurrence of `text`, as ranges for highlighting.
    func caseInsensitiveOccurrences(of text: String) -> [NSRange] {
        let haystack = self as NSString
        var result: [NSRange] = []
        var searchRange = NSRange(location: 0, length: haystack.length)
        while searchRange.length > 0 {
            let found = haystack.range(of: text, options: .caseInsensitive, range: searchRange)
            guard found.location != NSNotFound, found.length > 0 else { break }
            result.append(found)
            let next = found.location + found.length
            searchRange = NSRange(location: next, length: haystack.length - next)
        }
        return result
    }
}
