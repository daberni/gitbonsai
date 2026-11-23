import Foundation

extension Repository {
    /// Tags `commit` with `name`. A message makes it an annotated tag carrying tagger and date. Fails when the tag exists.
    public func createTag(_ name: String, at commit: String, message: String? = nil) async throws {
        if let message {
            _ = try await runner.runWrite(["tag", "-a", name, "-F", "-", commit], stdin: Data(message.utf8))
        } else {
            _ = try await runner.runWrite(["tag", name, commit])
        }
    }

    static let tagFormat = "--format=" + ["%(refname:strip=2)", "%(objecttype)", "%(objectname)", "%(*objectname)", "%(creatordate:unix)", "%(contents:subject)"].joined(separator: "%1f") + "%1e"

    /// All local tags, newest first. Tags that point at something other than a commit, such as a tree or a blob, are left out.
    public func tags() async throws -> [Tag] {
        let result = try await runner.run(["for-each-ref", "--sort=-creatordate", Self.tagFormat, "refs/tags"])
        return Self.parseTags(result.stdout)
    }

    static func parseTags(_ data: Data) -> [Tag] {
        FieldRecords.parse(data).compactMap { fields in
            guard fields.count == 6 else { return nil }
            let isAnnotated = fields[1] == "tag"
            let commitID = isAnnotated ? fields[3] : fields[2]
            // An annotated tag of a tag peels to the innermost object; anything but a commit has no place in the history.
            guard !fields[0].isEmpty, !commitID.isEmpty, isAnnotated || fields[1] == "commit" else { return nil }
            let seconds = TimeInterval(fields[4]) ?? 0
            return Tag(name: fields[0], commitID: commitID, isAnnotated: isAnnotated, date: Date(timeIntervalSince1970: seconds), subject: fields[5])
        }
    }

    public func deleteTag(_ name: String) async throws {
        _ = try await runner.runWrite(["tag", "--delete", name])
    }

    public func pushTag(_ name: String, to remote: String) async throws {
        _ = try await runner.runWithoutIndex(["push", remote, "refs/tags/\(name)"])
    }

    /// Deletes the tag on the remote only; the local tag stays.
    public func deleteRemoteTag(_ name: String, on remote: String) async throws {
        _ = try await runner.runWithoutIndex(["push", remote, "--delete", "refs/tags/\(name)"])
    }
}
