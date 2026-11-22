import Foundation

/// A repository found on disk, with the linked worktrees that belong to it.
public struct DiscoveredRepository: Sendable, Codable, Hashable {
    /// The working tree, which is the folder that holds `.git`.
    public let path: String
    /// The checked-out branch, or the abbreviated commit of a detached HEAD; nil when HEAD could not be read.
    public var branch: String?
    /// True for a linked worktree or submodule whose repository lies outside the scanned folders, so it stands on its own.
    public let isLinked: Bool
    public var worktrees: [Worktree]

    public struct Worktree: Sendable, Codable, Hashable {
        public let path: String
        public var branch: String?

        public init(path: String, branch: String?) {
            self.path = path
            self.branch = branch
        }
    }

    public init(path: String, branch: String?, isLinked: Bool = false, worktrees: [Worktree] = []) {
        self.path = path
        self.branch = branch
        self.isLinked = isLinked
        self.worktrees = worktrees
    }
}

/// Finds repositories below a folder with the filesystem alone: no git process, so a scan over thousands of folders stays cheap.
/// A folder is a repository when it holds a `.git` directory or a `.git` file (linked worktrees and submodules). The scan does not descend into a repository, so nested repositories and submodules belong to their parent.
public enum RepositoryDiscovery {
    public static let defaultDepth = 6
    /// Folders that hold dependencies or build output and never a repository worth listing.
    public static let skippedNames: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", "vendor"]

    /// Repositories below `root`, sorted by path. `depth` counts folder levels below `root`; `root` itself may be a repository.
    /// Paths come with links resolved, the way git records worktrees, so they compare equal to the paths git reports.
    public static func scan(_ root: String, depth: Int = defaultDepth) -> [DiscoveredRepository] {
        var found: [Found] = []
        visit(RealPath.of(root), level: 0, depth: depth, into: &found)
        return assemble(found)
    }

    /// What HEAD points to in the working tree at `path`, read the way git stores it: the branch name of `ref: refs/heads/…`, or the abbreviated commit.
    public static func branch(ofWorkingTree path: String) -> String? {
        guard let gitDirectory = gitDirectory(ofWorkingTree: path) else { return nil }
        return branch(inGitDirectory: gitDirectory)
    }

    // MARK: Walking

    private struct Found {
        let path: String
        let gitDirectory: String
        let isLinked: Bool
    }

    private static func visit(_ path: String, level: Int, depth: Int, into found: inout [Found]) {
        let entries = directoryEntries(path)
        if let dotGit = entries.first(where: { $0.name == ".git" }) {
            let marker = path + "/.git"
            if dotGit.isDirectory {
                if FileManager.default.fileExists(atPath: marker + "/HEAD") { found.append(Found(path: path, gitDirectory: marker, isLinked: false)) }
            } else if let gitDirectory = gitDirectory(ofWorkingTree: path) {
                found.append(Found(path: path, gitDirectory: gitDirectory, isLinked: true))
            }
            return
        }
        guard level < depth else { return }
        for entry in entries where entry.isDirectory && !entry.name.hasPrefix(".") && !skippedNames.contains(entry.name) {
            visit(path + "/" + entry.name, level: level + 1, depth: depth, into: &found)
        }
    }

    private struct Entry {
        let name: String
        let isDirectory: Bool
    }

    /// `readdir` reports the type with each name, so a folder of thousands of entries costs no `stat` per entry. Symbolic links are not followed, which keeps loops out.
    private static func directoryEntries(_ path: String) -> [Entry] {
        guard let directory = opendir(path) else { return [] }
        defer { closedir(directory) }
        var entries: [Entry] = []
        while let entry = readdir(directory) {
            let type = entry.pointee.d_type
            guard type == DT_DIR || type == DT_REG else { continue }
            let name = withUnsafeBytes(of: entry.pointee.d_name) { buffer in
                String(decoding: buffer.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            entries.append(Entry(name: name, isDirectory: type == DT_DIR))
        }
        return entries
    }

    // MARK: Grouping

    /// Linked worktrees go under their main repository, which lists every worktree it knows of, also those outside the scanned folder. A linked worktree or submodule whose repository was not found stays on its own.
    private static func assemble(_ found: [Found]) -> [DiscoveredRepository] {
        let mains = found.filter { !$0.isLinked }
        let mainDirectories = Set(mains.map { RealPath.of($0.gitDirectory) })
        var repositories = mains.map { main in
            DiscoveredRepository(path: main.path, branch: branch(inGitDirectory: main.gitDirectory), worktrees: linkedWorktrees(of: main.gitDirectory))
        }
        for linked in found where linked.isLinked {
            guard !mainDirectories.contains(RealPath.of(commonDirectory(of: linked.gitDirectory))) else { continue }
            repositories.append(DiscoveredRepository(path: linked.path, branch: branch(inGitDirectory: linked.gitDirectory), isLinked: true))
        }
        return repositories.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// `<git dir>/worktrees/<name>/gitdir` names the `.git` file of each linked worktree; a worktree whose folder is gone is left out.
    private static func linkedWorktrees(of gitDirectory: String) -> [DiscoveredRepository.Worktree] {
        let administrative = gitDirectory + "/worktrees"
        let names = directoryEntries(administrative).filter(\.isDirectory).map(\.name)
        let worktrees = names.compactMap { name -> DiscoveredRepository.Worktree? in
            let entry = administrative + "/" + name
            guard let marker = firstLine(of: entry + "/gitdir") else { return nil }
            let path = URL(fileURLWithPath: marker).deletingLastPathComponent().path
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return DiscoveredRepository.Worktree(path: path, branch: branch(inGitDirectory: entry))
        }
        return worktrees.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    // MARK: Reading git's files

    private static func gitDirectory(ofWorkingTree path: String) -> String? {
        let marker = path + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return marker }
        guard let line = firstLine(of: marker), line.hasPrefix("gitdir: ") else { return nil }
        let target = String(line.dropFirst("gitdir: ".count))
        return resolve(target, relativeTo: path)
    }

    /// A linked worktree's git directory names the shared one in `commondir`, usually as `../..`.
    private static func commonDirectory(of gitDirectory: String) -> String {
        guard let common = firstLine(of: gitDirectory + "/commondir") else { return gitDirectory }
        return resolve(common, relativeTo: gitDirectory)
    }

    private static func branch(inGitDirectory gitDirectory: String) -> String? {
        guard let head = firstLine(of: gitDirectory + "/HEAD") else { return nil }
        if head.hasPrefix("ref: ") {
            let ref = head.dropFirst("ref: ".count)
            return ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : String(ref)
        }
        return String(head.prefix(7))
    }

    private static func firstLine(of file: String) -> String? {
        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        let line = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.trimmingCharacters(in: .whitespaces)
    }

    private static func resolve(_ path: String, relativeTo base: String) -> String {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: base).appendingPathComponent(path)
        return url.standardizedFileURL.path
    }
}
