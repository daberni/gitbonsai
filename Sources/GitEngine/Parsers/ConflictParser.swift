import Foundation

/// Reads what the conflict view needs from git: the stages of `git ls-files -u -z`, the hunks of `git diff -U0` that align the three stages, and the token files `git merge-file` merges word by word.
enum ConflictParser {
    /// `mode SP oid SP stage TAB path NUL` per stage of every unmerged path.
    static func parseStages(_ data: Data) -> [String: ConflictStages] {
        var result: [String: ConflictStages] = [:]
        for record in data.split(separator: 0) {
            let line = String(decoding: record, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let fields = line[..<tab].split(separator: " ")
            guard fields.count == 3, let stage = Int(fields[2]) else { continue }
            let path = String(line[line.index(after: tab)...])
            let blob = ConflictBlob(mode: String(fields[0]), oid: String(fields[1]))
            var stages = result[path] ?? ConflictStages()
            switch stage {
            case 1: stages.base = blob
            case 2: stages.ours = blob
            case 3: stages.theirs = blob
            default: continue
            }
            result[path] = stages
        }
        return result
    }

    /// One hunk of `git diff -U0`, zero-based: `count` lines from `start` in the base become `sideCount` lines from `sideStart` in the side. A count of 0 is an insertion before `start`.
    struct Hunk: Equatable {
        let start: Int
        let count: Int
        let sideStart: Int
        let sideCount: Int

        var end: Int { start + count }
    }

    /// The `@@ -a[,b] +c[,d] @@` lines of `git diff -U0`. git numbers from 1 and names the line before an insertion, so a count of 0 keeps its start.
    static func parseHunks(_ data: Data) -> [Hunk] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> Hunk? in
            guard line.hasPrefix("@@ ") else { return nil }
            let parts = line.split(separator: " ")
            guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
            func range(_ token: Substring) -> (Int, Int) {
                let numbers = token.dropFirst().split(separator: ",").compactMap { Int($0) }
                let count = numbers.count > 1 ? numbers[1] : 1
                let start = numbers.first ?? 0
                return (count == 0 ? start : start - 1, count)
            }
            let (start, count) = range(parts[1])
            let (sideStart, sideCount) = range(parts[2])
            return Hunk(start: start, count: count, sideStart: sideStart, sideCount: sideCount)
        }
    }

    /// The lines of a file, split on the newline byte before decoding so a carriage return stays at the end of its line; whether the last line ends with a newline.
    static func lines(of data: Data, encoding: MergeDocument.Encoding) -> (lines: [String], endsWithNewline: Bool) {
        var parts = data.split(separator: 0x0A, omittingEmptySubsequences: false).map { encoding.decode(Data($0)) }
        let endsWithNewline = parts.last == ""
        if endsWithNewline { parts.removeLast() }
        return (parts, endsWithNewline || data.isEmpty)
    }

    /// The three-way merge of `ours` and `theirs` against `base`, from git's diff of each side against the base, the way diff3 does it:
    /// hunks of both sides that overlap or touch form one change; where only one side has hunks, the change is that side's.
    static func align(base: [String], ours: [String], theirs: [String], oursHunks: [Hunk], theirsHunks: [Hunk]) -> [MergeDocument.Region] {
        var regions: [MergeDocument.Region] = []
        var pending = (oursHunks.map { (hunk: $0, isOurs: true) } + theirsHunks.map { (hunk: $0, isOurs: false) }).sorted { $0.hunk.start < $1.hunk.start }[...]
        var position = 0
        // How many more lines each side has than the base before the current position.
        var oursShift = 0
        var theirsShift = 0
        while let first = pending.first {
            let low = first.hunk.start
            var high = first.hunk.end
            var group: [(hunk: Hunk, isOurs: Bool)] = []
            while let next = pending.first, next.hunk.start <= high {
                group.append(next)
                high = max(high, next.hunk.end)
                pending = pending.dropFirst()
            }
            if position < low { regions.append(.same(Array(base[position..<low]))) }
            func side(_ lines: [String], isOurs: Bool, shift: inout Int) -> (lines: [String], changed: Bool) {
                let hunks = group.filter { $0.isOurs == isOurs }.map(\.hunk)
                let start = low + shift
                let delta = hunks.reduce(0) { $0 + $1.sideCount - $1.count }
                let end = high + shift + delta
                shift += delta
                return (Array(lines[max(0, min(start, lines.count))..<max(0, min(end, lines.count))]), !hunks.isEmpty)
            }
            let oursSide = side(ours, isOurs: true, shift: &oursShift)
            let theirsSide = side(theirs, isOurs: false, shift: &theirsShift)
            let kind: MergeChange.Kind = switch (oursSide.changed, theirsSide.changed) {
            case (true, false): .ours
            case (false, true): .theirs
            default: oursSide.lines == theirsSide.lines ? .both : .conflict
            }
            regions.append(.change(MergeChange(base: Array(base[low..<high]), ours: oursSide.lines, theirs: theirsSide.lines, kind: kind)))
            position = high
        }
        if position < base.count { regions.append(.same(Array(base[position...]))) }
        return regions
    }

    /// Words, runs of white space and single other characters, each on its own line for `git merge-file`; a newline becomes `newlineToken`, a character no text contains.
    static func tokenFile(_ lines: [String]) -> Data {
        var tokens: [String] = []
        for (index, line) in lines.enumerated() {
            if index > 0 { tokens.append(String(newlineToken)) }
            var current = ""
            var currentKind = 0
            for character in line {
                let kind = character.isLetter || character.isNumber || character == "_" ? 1 : character.isWhitespace ? 2 : 3
                if kind != currentKind || kind == 3, !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                current.append(character)
                currentKind = kind
            }
            if !current.isEmpty { tokens.append(current) }
        }
        return Data(tokens.map { $0 + "\n" }.joined().utf8)
    }

    /// The lines a merged token file stands for.
    static func lines(fromTokens data: Data) -> [String] {
        let text = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().joined()
        return text.split(separator: newlineToken, omittingEmptySubsequences: false).map(String.init)
    }

    static let newlineToken: Character = "\u{E002}"

    /// git's own test for binary content: a NUL byte among the first 8000 bytes.
    static func isBinary(_ data: Data) -> Bool {
        data.prefix(8000).contains(0)
    }
}
