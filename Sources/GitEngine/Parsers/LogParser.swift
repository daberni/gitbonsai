import Foundation

/// Parses the output of `git log` in the format produced by `LogFormat.formatArgument`.
///
/// Incremental: feed chunks as they arrive from the stream, get back every commit that is
/// complete so far. Records are NUL separated fields, each commit terminated by a record separator.
public struct LogParser: Sendable {
    private var buffer = Data()

    public init() {}

    /// Feeds one chunk of stdout and returns the commits completed by it.
    public mutating func feed(_ chunk: Data) -> [Commit] {
        buffer.append(chunk)
        var commits: [Commit] = []
        var searchStart = buffer.startIndex
        while let end = buffer[searchStart...].firstIndex(of: LogFormat.recordSeparator) {
            let record = buffer[searchStart..<end]
            if let commit = Self.parseRecord(record) {
                commits.append(commit)
            }
            searchStart = buffer.index(after: end)
        }
        if searchStart > buffer.startIndex {
            buffer = Data(buffer[searchStart...])
        }
        return commits
    }

    /// Returns a trailing partial commit, if the stream ended mid-record. Normally empty.
    public mutating func finish() -> [Commit] {
        defer { buffer = Data() }
        guard !buffer.isEmpty, let commit = Self.parseRecord(buffer[...]) else { return [] }
        return [commit]
    }

    private static func parseRecord(_ record: Data.SubSequence) -> Commit? {
        // git separates records with a newline after each record terminator; skip that leading newline.
        var fields = record.split(separator: LogFormat.fieldSeparator, maxSplits: 10, omittingEmptySubsequences: false)
        guard fields.count == 11 else { return nil }
        if let first = fields[0].first, first == 0x0A { fields[0] = fields[0].dropFirst() }
        func string(_ index: Int) -> String { String(decoding: fields[index], as: UTF8.self) }
        let id = string(0)
        // SHA-1 or SHA-256 object IDs.
        guard id.utf8.count == 40 || id.utf8.count == 64 else { return nil }
        let parents = string(1).split(separator: " ").map(String.init)
        let authorDate = Date(timeIntervalSince1970: TimeInterval(string(4)) ?? 0)
        let committerDate = Date(timeIntervalSince1970: TimeInterval(string(7)) ?? 0)
        var body = string(9)
        while body.hasSuffix("\n") { body.removeLast() }
        return Commit(
            id: id,
            parents: parents,
            authorName: string(2),
            authorEmail: string(3),
            authorDate: authorDate,
            committerName: string(5),
            committerEmail: string(6),
            committerDate: committerDate,
            subject: string(8),
            body: body,
            trailers: TrailerParser.parse(string(10))
        )
    }
}

public enum LogFormat {
    /// Field separator inside a record.
    public static let fieldSeparator: UInt8 = 0x1F
    /// Terminates a record. Placed at the very end of the format so `-z` is not needed.
    public static let recordSeparator: UInt8 = 0x1E

    /// `--format=` argument: id, parents, author name, author email, author date (unix), committer name, committer email, committer date (unix), subject, body, trailers (unfolded `Key: value` lines from git's trailer parser).
    ///
    /// Assumes commit messages never contain the 0x1E/0x1F control bytes; git does not forbid them, but no real-world tool emits them.
    public static var formatArgument: String {
        let fields = ["%H", "%P", "%an", "%ae", "%at", "%cn", "%ce", "%ct", "%s", "%b", "%(trailers:only,unfold)"]
        return "--format=" + fields.joined(separator: "%x1f") + "%x1e"
    }
}
