import Foundation
import XCTest
@testable import GitEngine

final class GitPathTests: XCTestCase {
    func testPreferredGitPathIsUsedByNewRepositories() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GIT_BONSAI_GIT"] != nil, "GIT_BONSAI_GIT takes precedence over the preference")
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("one")

        // A wrapper that logs every call and passes it on to the real git.
        let realGit = GitRunner.defaultGitPath()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gitpath-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let logFile = folder.appendingPathComponent("calls.log").path
        let wrapper = folder.appendingPathComponent("git").path
        try "#!/bin/sh\necho \"$@\" >> '\(logFile)'\nexec '\(realGit)' \"$@\"\n".write(toFile: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)

        GitRunner.preferredGitPath = wrapper
        defer { GitRunner.preferredGitPath = nil }
        let repository = Repository(path: fixture.path)
        XCTAssertEqual(repository.runner.gitPath, wrapper)
        _ = try await repository.runner.run(["rev-parse", "HEAD"])

        let calls = try String(contentsOfFile: logFile, encoding: .utf8)
        XCTAssertTrue(calls.contains("rev-parse HEAD"), calls)

        GitRunner.preferredGitPath = ""
        XCTAssertEqual(GitRunner.defaultGitPath(), GitRunner.automaticGitPath())
    }

    func testVersionOutputParsing() {
        XCTAssertEqual(GitVersion(versionOutput: "git version 2.39.5 (Apple Git-154)\n")?.description, "2.39.5")
        XCTAssertEqual(GitVersion(versionOutput: "git version 2.47.1")?.description, "2.47.1")
        XCTAssertEqual(GitVersion(versionOutput: "git version 2.38.0.windows.1")?.description, "2.38.0")
        XCTAssertEqual(GitVersion(versionOutput: "git version 2.40")?.description, "2.40.0")
        XCTAssertNil(GitVersion(versionOutput: "zsh: command not found"))
    }

    func testMinimumVersionComparesNumerically() {
        XCTAssertLessThan(GitVersion(major: 2, minor: 9, patch: 0), .minimumSupported)
        XCTAssertLessThan(GitVersion(major: 2, minor: 37, patch: 9), .minimumSupported)
        XCTAssertFalse(GitVersion(major: 2, minor: 38, patch: 0) < .minimumSupported)
        XCTAssertFalse(GitVersion(major: 3, minor: 0, patch: 0) < .minimumSupported)
    }

    func testVersionOfInstalledGit() async throws {
        let version = try await GitRunner.version(ofGitAt: GitRunner.defaultGitPath())
        XCTAssertGreaterThanOrEqual(version.major, 2)
    }
}
