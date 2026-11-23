import Foundation

/// What is at a path where git is to create a folder, for a clone or a worktree.
public enum FolderDestination: Equatable, Sendable {
    case missing, file, emptyFolder, occupiedFolder, unreadableFolder

    /// git takes only a missing path or an empty folder, and every entry counts, hidden ones such as `.DS_Store` too.
    public static func at(_ path: String) -> FolderDestination {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .file }
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: path) else { return .unreadableFolder }
        return contents.isEmpty ? .emptyFolder : .occupiedFolder
    }

    /// True where git can create the folder's content.
    public var acceptsNewContent: Bool { self == .missing || self == .emptyFolder }
}
