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
