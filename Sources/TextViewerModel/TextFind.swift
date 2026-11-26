import Foundation

/// Every occurrence of a search text in a document, case and diacritics ignored, and the next one in either direction from a place.
public struct TextFind: Sendable {
    public let query: String
    /// UTF-16 ranges in document order.
    public let matches: [NSRange]

    public init(_ query: String, in document: TextDocument) {
        self.query = query
        guard !query.isEmpty else {
            matches = []
            return
        }
        let text = document.text as NSString
        var found: [NSRange] = []
        var searchRange = NSRange(location: 0, length: text.length)
        while searchRange.length > 0 {
            let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            guard match.location != NSNotFound else { break }
            found.append(match)
            let next = NSMaxRange(match)
            searchRange = NSRange(location: next, length: text.length - next)
        }
        matches = found
    }

    /// The index of the match after `offset` going forward, or before it going backward; wraps around the document's end.
    public func next(after offset: Int, forward: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        if forward {
            return matches.firstIndex { $0.location > offset } ?? 0
        }
        return matches.lastIndex { $0.location < offset } ?? matches.count - 1
    }
}
