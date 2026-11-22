import Foundation

/// Parses `git for-each-ref` output in the format produced by `formatArgument`.
public enum RefsParser {
    /// `--format=` argument: refname, objecttype, objectname, peeled objectname (`*objectname`), HEAD marker, upstream short name, upstream track (`[ahead 1, behind 2]`).
    public static var formatArgument: String {
        let fields = ["%(refname)", "%(objecttype)", "%(objectname)", "%(*objectname)", "%(HEAD)", "%(upstream:short)", "%(upstream:track)"]
        return "--format=" + fields.joined(separator: "%1f") + "%1e"
    }

    public static func parse(_ data: Data) throws -> [Ref] {
        var refs: [Ref] = []
        for fields in FieldRecords.parse(data) {
            guard fields.count == 7 else { continue }
            let fullName = fields[0]
            guard !fullName.isEmpty else { continue }
            let peeled = fields[3]
            let (kind, name) = classify(fullName)
            let (ahead, behind) = parseTrack(fields[6])
            refs.append(Ref(
                fullName: fullName,
                name: name,
                kind: kind,
                target: peeled.isEmpty ? fields[2] : peeled,
                isHead: fields[4] == "*",
                upstream: fields[5].isEmpty ? nil : fields[5],
                ahead: ahead,
                behind: behind
            ))
        }
        return refs
    }

    static func classify(_ fullName: String) -> (RefKind, String) {
        if let name = strip(fullName, "refs/heads/") { return (.localBranch, name) }
        if let name = strip(fullName, "refs/remotes/") {
            let remote = name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? name
            return (.remoteBranch(remote: remote), name)
        }
        if let name = strip(fullName, "refs/tags/") { return (.tag, name) }
        if fullName == "refs/stash" { return (.stash, "stash") }
        return (.other, fullName)
    }

    private static func strip(_ value: String, _ prefix: String) -> String? {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : nil
    }

    /// Parses `[ahead 1, behind 2]`, `[ahead 1]`, `[behind 2]`, `[gone]` or empty. Gone upstreams report nil counts.
    static func parseTrack(_ track: String) -> (Int?, Int?) {
        guard track.hasPrefix("["), track.hasSuffix("]") else { return (nil, nil) }
        let inner = track.dropFirst().dropLast()
        if inner == "gone" { return (nil, nil) }
        var ahead = 0
        var behind = 0
        for part in inner.split(separator: ",") {
            let words = part.trimmingCharacters(in: .whitespaces).split(separator: " ")
            guard words.count == 2, let count = Int(words[1]) else { continue }
            if words[0] == "ahead" { ahead = count }
            if words[0] == "behind" { behind = count }
        }
        return (ahead, behind)
    }
}
