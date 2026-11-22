import Foundation
import XCTest

/// Builds throwaway repositories with the real git binary. Each fixture lives in its own temp dir and is removed on `tearDown` of the owning test.
final class FixtureRepo {
    let url: URL
    var path: String { url.path }

    convenience init(name: String = "fixture") throws {
        try self.init(at: FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-\(name)-\(UUID().uuidString)", isDirectory: true))
    }

    /// A repository in a given folder, for tests that lay out several repositories in one tree.
    init(at url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Fixture")
        try git("config", "user.email", "fixture@example.com")
        try git("config", "commit.gpgsign", "false")
    }

    /// A repository that already exists, such as a clone, to run git in.
    init(existing url: URL) {
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
    func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = url
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_AUTHOR_DATE"] = environment["GIT_AUTHOR_DATE"] ?? "2024-01-01T12:00:00+0000"
        environment["GIT_COMMITTER_DATE"] = environment["GIT_COMMITTER_DATE"] ?? "2024-01-01T12:00:00+0000"
        process.environment = environment
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

    struct FixtureError: Error, CustomStringConvertible {
        let command: String
        let stderr: String
        var description: String { "git \(command): \(stderr)" }
    }
}
