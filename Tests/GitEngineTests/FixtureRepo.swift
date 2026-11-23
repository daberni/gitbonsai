import Foundation
import XCTest
@testable import GitEngine

/// Builds throwaway repositories with the real git binary. Each fixture lives in its own temp dir and is removed on `tearDown` of the owning test.
final class FixtureRepo {
    let url: URL
    var path: String { url.path }

    convenience init(name: String = "fixture") throws {
        try self.init(at: FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-\(name)-\(UUID().uuidString)", isDirectory: true))
    }

    /// A repository in a given folder, for tests that lay out several repositories in one tree.
    init(at url: URL) throws {
        TestGitEnvironment.isolate()
        self.url = url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Fixture")
        try git("config", "user.email", "fixture@example.com")
        try git("config", "commit.gpgsign", "false")
    }

    /// A repository that already exists, such as a clone, to run git in.
    init(existing url: URL) {
        TestGitEnvironment.isolate()
        self.url = url
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try git(arguments)
    }

    @discardableResult
    func git(_ arguments: [String], date: String? = nil) throws -> String {
        let process = Process()
        // The git the engine runs, with the environment it gives git, so fixtures and engine agree on formats and configuration.
        process.executableURL = URL(fileURLWithPath: TestGitEnvironment.gitPath)
        process.arguments = arguments
        process.currentDirectoryURL = url
        let fixedDate = date ?? "2024-01-01T12:00:00+0000"
        process.environment = ProcessExecution.environment(inherited: ProcessInfo.processInfo.environment, overrides: ["GIT_TERMINAL_PROMPT": "0", "GIT_AUTHOR_DATE": fixedDate, "GIT_COMMITTER_DATE": fixedDate])
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError(command: arguments.joined(separator: " "), stderr: String(decoding: errorOutput, as: UTF8.self))
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Writes a file, stages it and commits. Returns the new commit SHA.
    @discardableResult
    func commit(_ message: String, file: String = "file.txt", contents: String? = nil) throws -> String {
        try write(file, contents ?? "\(message)\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", message)
        return try git("rev-parse", "HEAD")
    }

    /// A commit with author and committer date `date` (ISO 8601), for tests that depend on git's date order.
    @discardableResult
    func commit(_ message: String, date: String) throws -> String {
        try write("file.txt", "\(message)\n")
        try git("add", "-A")
        try git(["commit", "-q", "-m", message], date: date)
        return try git("rev-parse", "HEAD")
    }

    struct FixtureError: Error, CustomStringConvertible {
        let command: String
        let stderr: String
        var description: String { "git \(command): \(stderr)" }
    }
}

/// Keeps the user's git configuration out of every test: fixtures and the engine read one generated global config and no system config.
/// The engine passes `GIT_CONFIG_GLOBAL` and `GIT_CONFIG_NOSYSTEM` through to git, so setting them for the test process covers both.
enum TestGitEnvironment {
    static let gitPath = GitRunner.defaultGitPath()

    private static let configured: Void = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = directory.appendingPathComponent("gitconfig")
        // Clones in tests commit too and need an identity; local submodules are refused by default since git 2.38.
        let contents = """
        [user]
        \tname = Fixture
        \temail = fixture@example.com
        [init]
        \tdefaultBranch = main
        [commit]
        \tgpgsign = false
        [tag]
        \tgpgsign = false
        [protocol "file"]
        \tallow = always

        """
        try? contents.write(to: config, atomically: true, encoding: .utf8)
        setenv("GIT_CONFIG_GLOBAL", config.path, 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    }()

    static func isolate() {
        _ = configured
    }
}
