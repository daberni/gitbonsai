import Foundation
import GitEngine

/// Inputs the benchmarks share. Repositories are generated once into `.build/benchmark-fixtures` and reused by later runs.
enum Fixtures {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let directory = packageRoot.appendingPathComponent(".build/benchmark-fixtures")

    /// A repository from `scripts/make-synthetic-repo.sh` with a commit-graph, as the app writes one on opening.
    static func syntheticRepository(commits: Int, branches: Int) async throws -> URL {
        let url = directory.appendingPathComponent("synthetic-\(commits)-\(branches)")
        let ready = directory.appendingPathComponent("synthetic-\(commits)-\(branches).ready")
        if FileManager.default.fileExists(atPath: ready.path) { return url }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log("Generating \(url.path) …")
        try run(packageRoot.appendingPathComponent("scripts/make-synthetic-repo.sh"), [url.path, String(commits), String(branches)])
        guard await Repository(path: url.path).writeCommitGraphIfMissing() else { throw FixtureError("could not write the commit-graph of \(url.path)") }
        FileManager.default.createFile(atPath: ready.path, contents: Data())
        return url
    }

    /// Deterministic history in topological order: `strands` interleaved branches that periodically merge main in and get merged back, mirroring scripts/make-synthetic-repo.sh.
    static func syntheticHistory(count: Int, strands: Int) -> [Commit] {
        var heads: [String: String] = [:]
        var commits: [Commit] = []
        commits.reserveCapacity(count)
        func add(_ branch: String, _ parents: [String], _ index: Int) {
            let id = "c\(index)"
            commits.append(commit(id, parents: parents, subject: id))
            heads[branch] = id
        }
        add("main", [], 0)
        for i in 1..<count {
            let branch = i % 10 == 0 ? "main" : "feature/\(i % strands)"
            guard let head = heads[branch] else {
                add(branch, [heads["main"]!], i)
                continue
            }
            if branch != "main", i % 97 == 0 {
                add(branch, [head, heads["main"]!], i)
            } else if branch == "main", i % 500 == 0, let feature = heads["feature/\((i / 500) % strands)"] {
                add("main", [head, feature], i)
            } else {
                add(branch, [head], i)
            }
        }
        return commits.reversed()
    }

    private static func commit(_ id: String, parents: [String] = [], subject: String, body: String = "", author: String = "a", email: String = "a@x") -> Commit {
        let date = Date(timeIntervalSince1970: 0)
        return Commit(id: id, parents: parents, authorName: author, authorEmail: email, authorDate: date, committerName: author, committerEmail: email, committerDate: date, subject: subject, body: body)
    }

    /// Commits with subjects, bodies and authors like a real history, for the search.
    /// A Swift source file of `lines` lines in repeating declarations, comments and strings, as a large generated or vendored file would look.
    static func largeSourceFile(lines: Int) -> Data {
        var text = ""
        text.reserveCapacity(lines * 40)
        for index in 0..<(lines / 5) {
            text += "/// Entry \(index) of the table.\n"
            text += "struct Entry\(index): Codable {\n"
            text += "    let name = \"entry-\(index)\"\n"
            text += "    var count: Int = \(index * 3)\n"
            text += "}\n"
        }
        return Data(text.utf8)
    }

    static func searchableHistory(count: Int) -> [Commit] {
        (0..<count).map { index in
            commit(String(format: "%040x", index), subject: "Change number \(index) in module \(index % 97)", body: "Body line for commit \(index).\nRefs #\(index % 1000)", author: "Author \(index % 50)", email: "author\(index % 50)@example.com")
        }
    }

    /// A repository whose last commit adds `files` files, so selecting it fills the detail panel's file list.
    static func wideCommit(files: Int) async throws -> URL {
        let url = directory.appendingPathComponent("wide-\(files)")
        let ready = directory.appendingPathComponent("wide-\(files).ready")
        if FileManager.default.fileExists(atPath: ready.path) { return url }
        try? FileManager.default.removeItem(at: url)
        log("Generating \(url.path) …")
        let git = URL(fileURLWithPath: "/usr/bin/git")
        let identity = ["-c", "user.name=Bench", "-c", "user.email=bench@example.com", "-c", "commit.gpgsign=false"]
        try run(git, ["init", "-q", "-b", "main", url.path])
        try "# Wide\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try run(git, ["add", "-A"], in: url)
        try run(git, identity + ["commit", "-q", "-m", "Start"], in: url)
        for index in 0..<files {
            let folder = url.appendingPathComponent("Sources/Module\(index / 100)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "let value\(index) = \(index)\n".write(to: folder.appendingPathComponent("File\(index).swift"), atomically: false, encoding: .utf8)
        }
        try run(git, ["add", "-A"], in: url)
        try run(git, identity + ["commit", "-q", "-m", "Add \(files) files"], in: url)
        FileManager.default.createFile(atPath: ready.path, contents: Data())
        return url
    }

    /// Runs `executable` and returns its standard output; fails on a non-zero exit.
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FixtureError("\(executable.lastPathComponent) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)") }
        return data
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
