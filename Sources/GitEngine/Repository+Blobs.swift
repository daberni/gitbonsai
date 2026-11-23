import Foundation

/// Where one side of a file change is stored: an object git names by `<rev>:<path>` (`:<path>` for the index), or the file in the working tree.
public enum BlobLocation: Sendable, Hashable {
    case object(String)
    case workingTree(String)
}

/// The two sides of a file change; nil on the side the file does not exist, such as the old side of an added file.
public struct BlobSides: Sendable, Hashable {
    public let old: BlobLocation?
    public let new: BlobLocation?

    public init(old: BlobLocation?, new: BlobLocation?) {
        self.old = old
        self.new = new
    }
}

/// A Git LFS pointer file: the content lives on the LFS server, the repository holds only these few lines.
public struct LFSPointer: Sendable, Hashable {
    public let oid: String
    public let size: Int

    private static let header = Data("version https://git-lfs.github.com/spec/v1\n".utf8)

    /// Nil unless `data` is a pointer file as the LFS specification defines it.
    public init?(_ data: Data) {
        guard data.count < 1024, data.starts(with: Self.header), let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = String(parts[1]) }
        }
        guard let oid = values["oid"], let size = values["size"].flatMap(Int.init) else { return nil }
        self.oid = oid
        self.size = size
    }
}

extension Repository {
    /// Where the old and new content of a changed file is for a diff source. A renamed file's old side is read under its old path.
    public func blobSides(of diff: FileDiff, in source: DiffSource) -> BlobSides {
        let oldPath = diff.oldPath ?? diff.path
        let newPath = diff.path
        let old: BlobLocation?
        let new: BlobLocation?
        switch source {
        case .commit(let commit):
            old = commit.parents.first.map { .object("\($0):\(oldPath)") }
            new = .object("\(commit.id):\(newPath)")
        case .revisions(let base, let target):
            old = .object("\(base):\(oldPath)")
            new = .object("\(target):\(newPath)")
        case .staged:
            old = .object("HEAD:\(oldPath)")
            new = .object(":\(newPath)")
        case .unstaged:
            old = .object(":\(oldPath)")
            new = .workingTree(newPath)
        case .untracked:
            old = nil
            new = .workingTree(newPath)
        }
        return BlobSides(old: diff.isNew ? nil : old, new: diff.isDeleted ? nil : new)
    }

    /// The size in bytes, read without the content so large files can be shown on demand; nil when the side cannot be found.
    public func blobSize(at location: BlobLocation) async -> Int? {
        switch location {
        case .object(let name):
            guard let result = try? await runner.run(["cat-file", "-s", name]) else { return nil }
            return Int(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        case .workingTree(let relativePath):
            let attributes = try? FileManager.default.attributesOfItem(atPath: workingTreeURL(relativePath).path)
            return (attributes?[.size] as? NSNumber)?.intValue
        }
    }

    /// The raw content of one side as stored: no smudge filters, so an LFS file reads as its pointer.
    public func blobData(at location: BlobLocation) async throws -> Data {
        switch location {
        case .object(let name): try await runner.run(["cat-file", "blob", name]).stdout
        case .workingTree(let relativePath): try Data(contentsOf: workingTreeURL(relativePath))
        }
    }

    private func workingTreeURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: path).appendingPathComponent(relativePath)
    }
}
