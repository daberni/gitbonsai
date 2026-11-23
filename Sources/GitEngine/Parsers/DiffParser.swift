import Foundation

/// Parses `git diff -p --no-color` output into files, hunks and numbered lines, with renames, copies, their similarity and mode changes from the extended header.
enum DiffParser {
    static func parse(_ data: Data) -> [FileDiff] {
        // Split on the newline byte before decoding: a CR stays at the end of its line instead of forming one character with the LF.
        // The raw bytes stay alongside: a patch for `git apply` must carry the file's own bytes, which decoding would replace where they are not UTF-8.
        var raw = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if raw.last?.isEmpty == true { raw.removeLast() }
        let lines = raw.map { String(decoding: $0, as: UTF8.self) }
        var files: [FileDiff] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("diff --git ") else { index += 1; continue }
            let start = index
            index += 1
            while index < lines.count, !lines[index].hasPrefix("diff --git ") { index += 1 }
            files.append(parseFile(lines[start..<index], raw: raw[start..<index]))
        }
        return files
    }

    /// The lines joined with a newline after each, as git printed them.
    private static func joined(_ raw: ArraySlice<Data>) -> Data {
        var data = Data()
        for line in raw {
            data.append(line)
            data.append(0x0A)
        }
        return data
    }

    private static func parseFile(_ lines: ArraySlice<String>, raw: ArraySlice<Data>) -> FileDiff {
        var header: [String] = []
        var hunks: [DiffHunk] = []
        var oldPath: String?
        var newPath: String?
        var renameFrom: String?
        var renameTo: String?
        var isCopy = false
        var similarity: Int?
        var oldMode: String?
        var newMode: String?
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
            else if line.hasPrefix("copy from ") { renameFrom = String(line.dropFirst("copy from ".count)); isCopy = true }
            else if line.hasPrefix("copy to ") { renameTo = String(line.dropFirst("copy to ".count)); isCopy = true }
            else if line.hasPrefix("similarity index ") { similarity = Int(line.dropFirst("similarity index ".count).dropLast()) }
            else if line.hasPrefix("old mode ") { oldMode = String(line.dropFirst("old mode ".count)) }
            else if line.hasPrefix("new mode ") { newMode = String(line.dropFirst("new mode ".count)) }
            else if line.hasPrefix("Binary files ") { isBinary = true }
            else if line.hasPrefix("--- ") { oldPath = path(after: "--- ", in: line, prefix: "a/") }
            else if line.hasPrefix("+++ ") { newPath = path(after: "+++ ", in: line, prefix: "b/") }
        }
        let headerEnd = rest.startIndex
        while let line = rest.first, line.hasPrefix("@@") {
            let start = rest.startIndex
            var body: [String] = [line]
            rest = rest.dropFirst()
            while let next = rest.first, !next.hasPrefix("@@") {
                body.append(next)
                rest = rest.dropFirst()
            }
            if let hunk = parseHunk(body, raw: joined(raw[start..<rest.startIndex])) { hunks.append(hunk) }
        }
        let gitLine = header.first ?? ""
        let fallback = Self.pathFromGitLine(gitLine)
        let path = renameTo ?? newPath ?? oldPath ?? fallback
        return FileDiff(path: path, oldPath: renameFrom, isCopy: isCopy, similarity: similarity, isNew: isNew, isDeleted: isDeleted, isBinary: isBinary, oldMode: oldMode, newMode: newMode, hunks: hunks, rawHeader: joined(raw[raw.startIndex..<headerEnd]))
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

    private static func parseHunk(_ body: [String], raw: Data) -> DiffHunk? {
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
            // Scalars, not characters: a combining mark right after the sign would merge with it into one character.
            let scalars = raw.unicodeScalars
            if scalars.first == "\\" {
                if let last = lines.popLast() { lines.append(DiffLine(kind: last.kind, text: last.text, oldNumber: last.oldNumber, newNumber: last.newNumber, missingNewline: true, carriageReturn: last.carriageReturn)) }
                continue
            }
            var body = scalars.dropFirst()
            let carriageReturn = body.last == "\r"
            if carriageReturn { body = body.dropLast() }
            let text = String(String.UnicodeScalarView(body))
            switch scalars.first {
            case "+":
                lines.append(DiffLine(kind: .added, text: text, oldNumber: nil, newNumber: newNumber, carriageReturn: carriageReturn))
                newNumber += 1
            case "-":
                lines.append(DiffLine(kind: .removed, text: text, oldNumber: oldNumber, newNumber: nil, carriageReturn: carriageReturn))
                oldNumber += 1
            default:
                lines.append(DiffLine(kind: .context, text: text, oldNumber: oldNumber, newNumber: newNumber, carriageReturn: carriageReturn))
                oldNumber += 1
                newNumber += 1
            }
        }
        return DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount, section: section, lines: lines, header: header, rawPatch: raw)
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
