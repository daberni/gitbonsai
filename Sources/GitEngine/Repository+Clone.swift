import Foundation

/// What `git clone` is asked to do besides copying the default branch.
public struct CloneOptions: Sendable, Equatable {
    public var recurseSubmodules = false
    /// Only the newest commit (`--depth 1`).
    public var shallow = false
    /// The branch to check out instead of the remote's default; nil or empty takes the default.
    public var branch: String?

    public init(recurseSubmodules: Bool = false, shallow: Bool = false, branch: String? = nil) {
        self.recurseSubmodules = recurseSubmodules
        self.shallow = shallow
        self.branch = branch
    }

    /// The options as `git clone` arguments.
    public var arguments: [String] {
        var arguments: [String] = []
        if recurseSubmodules { arguments.append("--recurse-submodules") }
        if shallow { arguments += ["--depth", "1"] }
        if let branch, !branch.isEmpty { arguments += ["--branch", branch] }
        return arguments
    }
}

/// One line of `git clone --progress`, such as "Receiving objects:  45% (450/1000)".
public struct CloneProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case counting = "Counting objects"
        case compressing = "Compressing objects"
        case receiving = "Receiving objects"
        case resolving = "Resolving deltas"
        case updatingFiles = "Updating files"
    }

    public let phase: Phase
    public let completed: Int
    public let total: Int

    public init(phase: Phase, completed: Int, total: Int) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }

    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }

    /// The progress lines in `output`, which git separates with carriage returns while a phase runs and a newline when it ends. Other lines are ignored.
    public static func parse(_ output: String) -> [CloneProgress] {
        output.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).compactMap { parseLine(String($0)) }
    }

    static func parseLine(_ line: String) -> CloneProgress? {
        var text = Substring(line)
        if text.hasPrefix("remote: ") { text = text.dropFirst("remote: ".count) }
        guard let colon = text.firstIndex(of: ":"), let phase = Phase(rawValue: String(text[..<colon])) else { return nil }
        guard let open = text.firstIndex(of: "("), let close = text[open...].firstIndex(of: ")") else { return nil }
        let counts = text[text.index(after: open)..<close].split(separator: "/")
        guard counts.count == 2, let completed = Int(counts[0]), let total = Int(counts[1]) else { return nil }
        return CloneProgress(phase: phase, completed: completed, total: total)
    }
}

/// Recognizes what a user may paste as the source of a clone and the folder name git would give it.
public enum CloneSource {
    /// URLs git can clone (`https://`, `ssh://`, `git://`, `file://`, `user@host:path`) and absolute or `~` paths of existing folders.
    public static func isCloneable(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isWhitespace) else { return false }
        let schemes = ["https://", "http://", "ssh://", "git://", "file://", "git+ssh://", "ssh+git://"]
        if schemes.contains(where: { value.lowercased().hasPrefix($0) }) { return repositoryName(of: value) != nil }
        if value.hasPrefix("/") || value.hasPrefix("~/") {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: (value as NSString).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return isScpLike(value)
    }

    /// The last path component without `.git`, like git's own default folder name; nil when the source names no path.
    public static func repositoryName(of source: String) -> String? {
        var value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.hasSuffix(".git") { value.removeLast(4) }
        while value.hasSuffix("/") { value.removeLast() }
        let afterHost: Substring
        if let scheme = value.range(of: "://") {
            let rest = value[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            afterHost = rest[slash...]
        } else if isScpLike(value), let colon = value.firstIndex(of: ":") {
            afterHost = value[value.index(after: colon)...]
        } else {
            afterHost = Substring(value)
        }
        let name = afterHost.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return name.isEmpty ? nil : name
    }

    /// `git@github.com:owner/repo.git`: a host before the first colon and no slash before it.
    private static func isScpLike(_ value: String) -> Bool {
        guard let colon = value.firstIndex(of: ":"), colon != value.startIndex else { return false }
        let host = value[..<colon]
        return !host.contains("/") && value.index(after: colon) < value.endIndex
    }
}

extension Repository {
    /// Clones `url` into `destination`, which must not exist or be an empty folder, and reports git's progress as it arrives.
    /// Cancelling the task stops git and removes what it had written, so no half-cloned folder stays behind.
    public static func clone(
        url: String,
        to destination: String,
        options: CloneOptions = CloneOptions(),
        gitPath: String = GitRunner.defaultGitPath(),
        progress: @escaping @Sendable (CloneProgress) -> Void = { _ in }
    ) async throws {
        let target = URL(fileURLWithPath: destination).standardizedFileURL
        let found = FolderDestination.at(target.path)
        let existedBefore = found != .missing
        // git refuses a folder with content; that content is the user's and must survive the failure.
        let ownsContent = found.acceptsNewContent
        let arguments = ["clone", "--progress"] + options.arguments + ["--", url, target.path]
        let reader = ProgressReader(progress)
        do {
            _ = try await GitRunner(repositoryPath: NSTemporaryDirectory(), gitPath: gitPath).runCreating(arguments) { reader.append($0) }
            try Task.checkCancellation()
        } catch {
            if ownsContent { removeLeftovers(at: target, existedBefore: existedBefore) }
            throw error
        }
    }

    /// A folder git created goes; a folder that was there and empty before keeps existing but is emptied again.
    private static func removeLeftovers(at target: URL, existedBefore: Bool) {
        let manager = FileManager.default
        if !existedBefore {
            try? manager.removeItem(at: target)
            return
        }
        for item in (try? manager.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] {
            try? manager.removeItem(at: item)
        }
    }
}

/// Splits stderr chunks into progress lines; a line may arrive in two chunks.
private final class ProgressReader: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private let report: @Sendable (CloneProgress) -> Void

    init(_ report: @escaping @Sendable (CloneProgress) -> Void) {
        self.report = report
    }

    func append(_ chunk: Data) {
        lock.lock()
        pending += String(decoding: chunk, as: UTF8.self)
        var lines: [String] = []
        while let end = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            lines.append(String(pending[..<end]))
            pending = String(pending[pending.index(after: end)...])
        }
        lock.unlock()
        for line in lines {
            if let progress = CloneProgress.parseLine(line) { report(progress) }
        }
    }
}
