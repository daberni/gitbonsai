import Foundation

extension Repository {
    /// Commits the index with `message`, or rewrites the last commit with `amend`.
    /// The message is passed as it is: lines starting with `#` stay, only surrounding blank lines and trailing spaces go.
    /// `trailers` and, with `signOff`, the committer's `Signed-off-by` are added with `--trailer`, except those the message already has, so amending never repeats them.
    public func commit(message: String, amend: Bool, trailers: [CommitTrailer] = [], signOff: Bool = false) async throws {
        var added = trailers
        if signOff, let signer = await committerIdentity() { added.append(CommitTrailer(key: CommitTrailer.signOffKey, value: signer)) }
        let existing = added.isEmpty ? [] : await self.trailers(of: message)
        let missing = added.filter { trailer in !existing.contains { $0.key.caseInsensitiveCompare(trailer.key) == .orderedSame && $0.value == trailer.value } }
        var arguments = ["commit", "--cleanup=whitespace", "-F", "-"] + (amend ? ["--amend"] : [])
        arguments += missing.flatMap { ["--trailer", $0.line] }
        _ = try await runner.runWrite(arguments, stdin: Data(message.utf8))
    }

    /// The text of the file `commit.template` names, without its `#` comment lines, or nil when none is set or it cannot be read.
    /// A relative path counts from the working tree's root, as git reads it for `git commit` run there.
    public func commitTemplate() async -> String? {
        guard let result = try? await runner.run(["config", "--path", "commit.template"]) else { return nil }
        let path = result.stdoutString.trimmingCharacters(in: .newlines)
        guard !path.isEmpty else { return nil }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: self.path, isDirectory: true))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n").filter { !$0.hasPrefix("#") }
        let template = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return template.isEmpty ? nil : template
    }

    /// `Name <email>` of the committer as git would record it, from `git var GIT_COMMITTER_IDENT`.
    public func committerIdentity() async -> String? {
        guard let result = try? await runner.run(["var", "GIT_COMMITTER_IDENT"]), let close = result.stdoutString.lastIndex(of: ">") else { return nil }
        return String(result.stdoutString[...close])
    }

    /// The trailers of `message` as `git interpret-trailers --parse` reads them.
    public func trailers(of message: String) async -> [CommitTrailer] {
        guard let result = try? await runner.run(["interpret-trailers", "--parse"], stdin: Data(message.utf8)) else { return [] }
        return TrailerParser.parse(result.stdoutString)
    }

    /// Everyone who authored a commit on any ref, most commits first, for the co-author picker; the mailmap applies.
    public func knownAuthors() async -> [KnownAuthor] {
        guard let result = try? await runner.run(["shortlog", "-sne", "--all"]) else { return [] }
        return KnownAuthor.parseShortlog(result.stdoutString)
    }

    /// The full message of HEAD, or nil before the first commit.
    public func lastCommitMessage() async -> String? {
        guard let result = try? await runner.run(["log", "-1", "--format=%B"]) else { return nil }
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How commits are signed according to the git configuration: "GPG", "SSH", "X.509", or nil when they are not.
    public func signingFormat() async -> String? {
        let sign = try? await runner.run(["config", "--bool", "commit.gpgsign"])
        guard sign?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { return nil }
        let format = (try? await runner.run(["config", "gpg.format"]))?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? "openpgp"
        switch format {
        case "ssh": return "SSH"
        case "x509": return "X.509"
        default: return "GPG"
        }
    }

    /// True when the upstream of the current branch already contains HEAD, so rewriting it needs a force push.
    public func headIsPushed() async -> Bool {
        (try? await runner.run(["merge-base", "--is-ancestor", "HEAD", "@{upstream}"])) != nil
    }
}
