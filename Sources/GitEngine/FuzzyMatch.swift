import Foundation

/// A query matched against a title: every character of each query word appears in order, ignoring case and diacritics.
/// Matches at the start of a word and runs of consecutive characters score higher, so "pf" prefers "Pull (Fast-Forward)" over "Stash apply".
public struct FuzzyMatch: Sendable, Equatable {
    public let score: Int
    /// The matched characters as UTF-16 ranges of the text, merged where they touch.
    public let ranges: [NSRange]

    private static let wordStartBonus = 8
    private static let consecutiveBonus = 5
    static let prefixBonus = 12
    private static let gapPenalty = 1

    /// Nil when the text does not contain the query's characters in order. An empty query matches with score 0.
    public static func match(_ query: String, in text: String) -> FuzzyMatch? {
        let needle = Array(fold(query))
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, ranges: []) }
        let characters = Array(text)
        let folded = characters.map { fold(String($0)).first ?? $0 }
        let starts = wordStarts(characters)
        var positions: [Int] = []
        var cursor = 0
        for (offset, wanted) in needle.enumerated() {
            let rest = needle[(offset + 1)...]
            // A word start ahead wins over an earlier mid-word hit, as long as the rest of the query still fits after it.
            let plain = (cursor..<folded.count).first { folded[$0] == wanted }
            guard let plain else { return nil }
            let atWord = (plain..<folded.count).first { folded[$0] == wanted && starts[$0] && fits(rest, in: folded, from: $0 + 1) }
            let continuesRun = positions.last.map { $0 + 1 == plain } ?? false
            let chosen = continuesRun || starts[plain] ? plain : atWord ?? plain
            positions.append(chosen)
            cursor = chosen + 1
        }
        var score = positions.count
        for (index, position) in positions.enumerated() {
            if starts[position] { score += wordStartBonus }
            if index > 0 {
                let gap = position - positions[index - 1] - 1
                score += gap == 0 ? consecutiveBonus : -min(gap, 10) * gapPenalty
            }
        }
        if positions.first == 0 { score += prefixBonus }
        return FuzzyMatch(score: score, ranges: utf16Ranges(of: positions, in: characters))
    }

    private static func fits(_ rest: ArraySlice<Character>, in text: [Character], from start: Int) -> Bool {
        var cursor = start
        for wanted in rest {
            guard let found = (cursor..<max(text.count, cursor)).first(where: { text[$0] == wanted }) else { return false }
            cursor = found + 1
        }
        return true
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The first character, one after a separator, and an uppercase letter after a lowercase one.
    private static func wordStarts(_ characters: [Character]) -> [Bool] {
        characters.indices.map { index in
            guard index > 0 else { return true }
            let previous = characters[index - 1]
            if !(previous.isLetter || previous.isNumber) { return true }
            return previous.isLowercase && characters[index].isUppercase
        }
    }

    private static func utf16Ranges(of positions: [Int], in characters: [Character]) -> [NSRange] {
        var offsets: [Int] = []
        var offset = 0
        for character in characters {
            offsets.append(offset)
            offset += character.utf16.count
        }
        var ranges: [NSRange] = []
        for position in positions {
            let range = NSRange(location: offsets[position], length: characters[position].utf16.count)
            if let last = ranges.last, NSMaxRange(last) == range.location {
                ranges[ranges.count - 1].length += range.length
            } else {
                ranges.append(range)
            }
        }
        return ranges
    }
}

/// Orders the command bar's entries for a query. Pure, so the ranking rules are testable without the panel.
public enum CommandRanking {
    public struct Candidate: Sendable {
        public let id: String
        public let title: String
        public let keywords: [String]
        public let isEnabled: Bool

        public init(id: String, title: String, keywords: [String] = [], isEnabled: Bool = true) {
            self.id = id
            self.title = title
            self.keywords = keywords
            self.isEnabled = isEnabled
        }
    }

    public struct Result: Sendable, Equatable {
        public let id: String
        /// What to highlight in the title; empty when only keywords matched.
        public let titleRanges: [NSRange]
    }

    /// A keyword is one word, so its hit always starts the text; without this discount any keyword would beat a word inside a title, as "editor" in the keywords of "Einstellungen …" would beat "Im Editor öffnen".
    private static let keywordDiscount = FuzzyMatch.prefixBonus + 2

    /// Every word of the query has to match the title or a keyword. Enabled entries come before disabled ones, then recently used ones in the order of `recent` (most recent first), then the best match; ties keep the registry's order.
    public static func rank(_ candidates: [Candidate], query: String, recent: [String]) -> [Result] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let recency = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var scored: [(index: Int, candidate: Candidate, score: Int, ranges: [NSRange])] = []
        for (index, candidate) in candidates.enumerated() {
            guard let (score, ranges) = match(words, candidate) else { continue }
            scored.append((index, candidate, score, ranges))
        }
        scored.sort { a, b in
            if a.candidate.isEnabled != b.candidate.isEnabled { return a.candidate.isEnabled }
            let ra = recency[a.candidate.id] ?? Int.max
            let rb = recency[b.candidate.id] ?? Int.max
            if ra != rb { return ra < rb }
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }
        return scored.map { Result(id: $0.candidate.id, titleRanges: $0.ranges) }
    }

    private static func match(_ words: [String], _ candidate: Candidate) -> (Int, [NSRange])? {
        var total = 0
        var ranges: [NSRange] = []
        for word in words {
            let inTitle = FuzzyMatch.match(word, in: candidate.title)
            let inKeywords = candidate.keywords.compactMap { FuzzyMatch.match(word, in: $0) }.map(\.score).max().map { $0 - keywordDiscount }
            switch (inTitle, inKeywords) {
            case (nil, nil): return nil
            case (let title?, let keyword?) where keyword > title.score: total += keyword
            case (let title?, _):
                total += title.score
                ranges += title.ranges
            case (nil, let keyword?): total += keyword
            }
        }
        return (total, ranges.sorted { $0.location < $1.location })
    }
}
