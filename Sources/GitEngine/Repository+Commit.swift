import Foundation

extension Repository {
    /// Commits the index with `message`, or rewrites the last commit with `amend`.
    /// The message is passed as it is: lines starting with `#` stay, only surrounding blank lines and trailing spaces go.
    public func commit(message: String, amend: Bool) async throws {
        let arguments = ["commit", "--cleanup=whitespace", "-F", "-"] + (amend ? ["--amend"] : [])
        _ = try await runner.runWrite(arguments, stdin: Data(message.utf8))
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
