import Foundation

/// Parses `git for-each-ref` output in the format produced by `formatArgument` into branch and tag tips with their commit.
public enum RefTipsParser {
    static let fieldSeparator: UInt8 = 0x1F
    static let recordSeparator: UInt8 = 0x1E

    /// `--format=` argument: refname, objectname, committer date and subject, each also peeled (`*`) for annotated tags.
    public static var formatArgument: String {
        let fields = ["%(refname)", "%(objectname)", "%(committerdate:unix)", "%(subject)", "%(*objectname)", "%(*committerdate:unix)", "%(*subject)"]
        return "--format=" + fields.joined(separator: "%1f") + "%1e"
    }

    /// Remote `HEAD` symrefs and tags of trees or blobs are left out: neither is a start point anyone picks.
    public static func parse(_ data: Data) -> [RefTip] {
        var tips: [RefTip] = []
        for record in data.split(separator: recordSeparator, omittingEmptySubsequences: true) {
            var fields = record.split(separator: fieldSeparator, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 7 else { continue }
            if fields[0].hasPrefix("\n") { fields[0].removeFirst() }
            let isPeeled = !fields[4].isEmpty
            let sha = isPeeled ? fields[4] : fields[1]
            guard let seconds = TimeInterval(isPeeled ? fields[5] : fields[2]) else { continue }
            let (kind, name) = RefsParser.classify(fields[0])
            switch kind {
            case .localBranch, .tag: break
            case .remoteBranch: if name.hasSuffix("/HEAD") { continue }
            case .stash, .other: continue
            }
            let commit = CommitSummary(sha: sha, date: Date(timeIntervalSince1970: seconds), subject: isPeeled ? fields[6] : fields[3])
            tips.append(RefTip(fullName: fields[0], name: name, kind: kind, commit: commit))
        }
        return tips
    }
}
