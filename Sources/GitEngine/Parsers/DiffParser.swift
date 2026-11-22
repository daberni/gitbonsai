import Foundation

/// Parses `git diff -p --no-color` output into files, hunks and numbered lines.
enum DiffParser {
    static func parse(_ data: Data) -> [FileDiff] {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var files: [FileDiff] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("diff --git ") else { index += 1; continue }
            let start = index
            index += 1
            while index < lines.count, !lines[index].hasPrefix("diff --git ") { index += 1 }
            files.append(parseFile(lines[start..<index]))
        }
        return files
    }

    private static func parseFile(_ lines: ArraySlice<String>) -> FileDiff {
        var header: [String] = []
        var hunks: [DiffHunk] = []
        var oldPath: String?
        var newPath: String?
        var renameFrom: String?
        var renameTo: String?
        var isNew = false
        var isDeleted = false
        var isBinary = false
        var rest = lines[...]
        while let line = rest.first, !line.hasPrefix("@@") {
            header.append(line)
            rest = rest.dropFirst()
            if line.hasPrefix("new file mode") { isNew = true }
            else if line.hasPrefix("deleted file mode") { isDeleted = true }
            else if line.hasPrefix("rename from ") { renameFrom = String(line.dropFirst("rename from ".count)) }
            else if line.hasPrefix("rename to ") { renameTo = String(line.dropFirst("rename to ".count)) }
            else if line.hasPrefix("copy from ") { renameFrom = String(line.dropFirst("copy from ".count)) }
            else if line.hasPrefix("copy to ") { renameTo = String(line.dropFirst("copy to ".count)) }
            else if line.hasPrefix("Binary files ") { isBinary = true }
            else if line.hasPrefix("--- ") { oldPath = path(after: "--- ", in: line, prefix: "a/") }
            else if line.hasPrefix("+++ ") { newPath = path(after: "+++ ", in: line, prefix: "b/") }
        }
        while let line = rest.first, line.hasPrefix("@@") {
            var body: [String] = [line]
            rest = rest.dropFirst()
            while let next = rest.first, !next.hasPrefix("@@") {
                body.append(next)
                rest = rest.dropFirst()
            }
            if let hunk = parseHunk(body) { hunks.append(hunk) }
        }
        let gitLine = header.first ?? ""
        let fallback = Self.pathFromGitLine(gitLine)
        let path = renameTo ?? newPath ?? oldPath ?? fallback
        return FileDiff(path: path, oldPath: renameFrom, isNew: isNew, isDeleted: isDeleted, isBinary: isBinary, hunks: hunks, headerLines: header)
    }

    /// `--- a/path` or `+++ b/path`; `/dev/null` stands for a missing side.
    private static func path(after marker: String, in line: String, prefix: String) -> String? {
        var value = String(line.dropFirst(marker.count))
        if value.hasSuffix("\t") { value.removeLast() }
        guard value != "/dev/null" else { return nil }
        return value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// `diff --git a/x b/x` for files whose hunks carry no `---`/`+++` lines, such as binaries and pure renames.
    private static func pathFromGitLine(_ line: String) -> String {
        guard let range = line.range(of: " b/", options: .backwards) else { return line }
        return String(line[range.upperBound...])
    }

    private static func parseHunk(_ body: [String]) -> DiffHunk? {
        // @@ -oldStart[,oldCount] +newStart[,newCount] @@ section
        let header = body[0]
        let parts = header.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        func range(_ token: Substring) -> (Int, Int) {
            let numbers = token.dropFirst().split(separator: ",").compactMap { Int($0) }
            return (numbers.first ?? 0, numbers.count > 1 ? numbers[1] : 1)
        }
        let (oldStart, oldCount) = range(parts[1])
        let (newStart, newCount) = range(parts[2])
        let section = parts.count > 4 ? String(parts[4]) : ""
        var lines: [DiffLine] = []
        var oldNumber = oldStart
        var newNumber = newStart
        for raw in body.dropFirst() {
            if raw.hasPrefix("\\") {
                if let last = lines.popLast() { lines.append(DiffLine(kind: last.kind, text: last.text, oldNumber: last.oldNumber, newNumber: last.newNumber, missingNewline: true)) }
                continue
            }
            let text = String(raw.dropFirst())
            switch raw.first {
            case "+":
                lines.append(DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: newNumber))
                newNumber += 1
            case "-":
                lines.append(DiffLine(kind: .removed, text: text, oldNumber: oldNumber, newNumber: nil))
                oldNumber += 1
            default:
                lines.append(DiffLine(kind: .context, text: text, oldNumber: oldNumber, newNumber: newNumber))
                oldNumber += 1
                newNumber += 1
            }
        }
        return DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, section: section, lines: lines, rawLines: body)
    }

    /// `--numstat -z`: `added TAB removed TAB path NUL`, and for renames `added TAB removed TAB NUL old NUL new NUL`. Binary files show `-`.
    static func parseNumstat(_ data: Data) -> [String: DiffStat] {
        var tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }[...]
        var result: [String: DiffStat] = [:]
        while let record = tokens.popFirst(), !record.isEmpty {
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            var path = String(fields[2])
            if path.isEmpty {
                _ = tokens.popFirst()
                path = tokens.popFirst() ?? ""
            }
            if let added = Int(fields[0]), let removed = Int(fields[1]) { result[path] = DiffStat(added: added, removed: removed) }
        }
        return result
    }
}
