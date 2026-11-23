import Foundation
import XCTest
@testable import GitEngine

final class GitRunnerTests: XCTestCase {
    func testCommandLogRecordsReadsAndFailures() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("one")
        let runner = GitRunner(repositoryPath: fixture.path)

        let result = try await runner.run(["rev-parse", "HEAD"])
        XCTAssertEqual(result.stdoutString.count, 41)
        do {
            _ = try await runner.run(["rev-parse", "does-not-exist"])
            XCTFail("expected failure")
        } catch let error as GitError {
            XCTAssertEqual(error.exitCode, 128)
            XCTAssertTrue(error.stderr.contains("does-not-exist"))
        }

        let log = await runner.commandLog
        XCTAssertEqual(log.map(\.result.exitCode), [0, 128])
        XCTAssertEqual(log[1].result.arguments, ["rev-parse", "does-not-exist"])
    }

    func testStreamFailureSurfacesGitError() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let runner = GitRunner(repositoryPath: fixture.path)

        do {
            for try await _ in runner.stream(["log", "nope"]) {}
            XCTFail("expected failure")
        } catch let error as GitError {
            XCTAssertNotEqual(error.exitCode, 0)
        }
    }

    func testCancellingStreamTerminatesGit() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("one")
        let runner = GitRunner(repositoryPath: fixture.path)

        // `cat-file --batch` blocks on stdin forever, so git only exits if cancellation terminates it.
        let consumer = Task {
            for try await _ in runner.stream(["cat-file", "--batch"]) {}
        }
        try await Task.sleep(for: .milliseconds(200))
        consumer.cancel()
        let finished = await withTimeout(seconds: 3) { _ = await consumer.result }
        XCTAssertTrue(finished, "stream did not end after cancellation")
    }

    func testWritesAreSerializedAndStdinIsDelivered() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        try fixture.commit("one")
        let runner = GitRunner(repositoryPath: fixture.path)

        let hashed = try await runner.runWrite(["hash-object", "-w", "--stdin"], stdin: Data("payload\n".utf8))
        let sha = hashed.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(sha.count, 40)

        async let a = runner.runWrite(["update-ref", "refs/test/a", "HEAD"])
        async let b = runner.runWrite(["update-ref", "refs/test/b", "HEAD"])
        _ = try await (a, b)
        let refs = try await Repository(path: fixture.path).refs().filter { $0.fullName.hasPrefix("refs/test/") }
        XCTAssertEqual(refs.count, 2)
    }

    private func withTimeout(seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await work(); return true }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// What git inherits from the app: a hook or parent git exports variables that would point git at another repository.
final class GitEnvironmentTests: XCTestCase {
    func testInheritedRepositoryVariablesDoNotRedirectGit() async throws {
        let fixture = try FixtureRepo(name: "env-target")
        let other = try FixtureRepo(name: "env-other")
        defer {
            fixture.remove()
            other.remove()
        }
        try fixture.commit("one")
        try other.git("checkout", "-q", "-b", "elsewhere")
        try other.commit("other")
        let inherited = ["GIT_DIR": other.path + "/.git", "GIT_WORK_TREE": other.path, "GIT_INDEX_FILE": other.path + "/.git/index"]
        for (name, value) in inherited { setenv(name, value, 1) }
        defer { for name in inherited.keys { unsetenv(name) } }

        let branches = try await fixture.repository.refs().filter { $0.kind == .localBranch }.map(\.name)
        XCTAssertEqual(branches, ["main"])
        try fixture.write("new.txt", "new\n")
        try await fixture.repository.stage(["new.txt"])
        unsetenv("GIT_INDEX_FILE")
        XCTAssertEqual(try fixture.git("diff", "--cached", "--name-only"), "new.txt")
    }

    func testUserChosenTransportAndConfigVariablesStay() {
        let inherited = ["GIT_DIR": "/x", "GIT_CONFIG_PARAMETERS": "'a.b=c'", "GIT_AUTHOR_DATE": "1", "GIT_SSH_COMMAND": "ssh -i k", "GIT_CONFIG_GLOBAL": "/g", "GIT_TRACE": "1", "PATH": "/bin"]
        let environment = ProcessExecution.environment(inherited: inherited, overrides: ["GIT_TERMINAL_PROMPT": "0"])
        XCTAssertEqual(Set(environment.keys), ["GIT_SSH_COMMAND", "GIT_CONFIG_GLOBAL", "GIT_TRACE", "PATH", "GIT_TERMINAL_PROMPT"])
    }

    func testCommandLogKeepsOnlyTheStartOfLargeOutput() async throws {
        let fixture = try FixtureRepo()
        defer { fixture.remove() }
        let large = String(repeating: "x", count: GitRunner.commandLogOutputLimit * 4) + "\n"
        try fixture.commit("large", file: "large.txt", contents: large)
        let runner = GitRunner(repositoryPath: fixture.path)

        let result = try await runner.run(["show", "HEAD:large.txt"])
        XCTAssertEqual(result.stdout.count, large.utf8.count)
        let logged = await runner.commandLog.last?.result.stdout.count
        XCTAssertEqual(logged, GitRunner.commandLogOutputLimit)
    }
}
