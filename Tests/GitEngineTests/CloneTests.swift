import Foundation
import XCTest
@testable import GitEngine

final class CloneTests: XCTestCase {
    private var base: URL!
    private var source: FixtureRepo!
    /// The source as a bare repository behind a `file://` URL, so clones go through the transport that reports progress and honors `--depth`.
    private var sourceURL: String!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-clone-\(UUID().uuidString)", isDirectory: true)
        source = try FixtureRepo(at: base.appendingPathComponent("work"))
        try source.commit("one")
        try source.commit("two", file: "second.txt")
        try source.git("branch", "feature")
        try source.git("clone", "-q", "--bare", source.path, base.appendingPathComponent("origin.git").path)
        sourceURL = base.appendingPathComponent("origin.git").absoluteString
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    private func destination(_ name: String) -> String {
        base.appendingPathComponent(name).path
    }

    private func git(_ arguments: String..., in path: String) throws -> String {
        try FixtureRepo(existing: URL(fileURLWithPath: path)).git(arguments)
    }

    func testClonesAndReportsProgressToTheEnd() async throws {
        let reports = ProgressLog()
        let target = destination("plain")

        try await Repository.clone(url: sourceURL, to: target) { reports.add($0) }

        XCTAssertEqual(RepositoryDiscovery.branch(ofWorkingTree: target), "main")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + "/second.txt"))
        let receiving = reports.all.filter { $0.phase == .receiving }
        XCTAssertFalse(receiving.isEmpty)
        XCTAssertEqual(receiving.last?.completed, receiving.last?.total)
    }

    func testShallowCloneHasOnlyTheNewestCommit() async throws {
        let target = destination("shallow")

        try await Repository.clone(url: sourceURL, to: target, options: CloneOptions(shallow: true))

        XCTAssertEqual(try git("rev-list", "--count", "HEAD", in: target), "1")
    }

    func testChecksOutTheChosenBranch() async throws {
        let target = destination("branch")

        try await Repository.clone(url: sourceURL, to: target, options: CloneOptions(branch: "feature"))

        XCTAssertEqual(RepositoryDiscovery.branch(ofWorkingTree: target), "feature")
    }

    func testClonesSubmodulesWhenAsked() async throws {
        let library = try FixtureRepo(at: base.appendingPathComponent("library"))
        try library.commit("library")
        try source.git("-c", "protocol.file.allow=always", "submodule", "add", "-q", library.path, "modules/library")
        try source.git("commit", "-q", "-m", "Add library")
        try source.git("push", "-q", base.appendingPathComponent("origin.git").path, "main")
        // Local submodules are refused by default since git 2.38; the tests' global config allows them, the user's own config decides outside the tests.

        try await Repository.clone(url: sourceURL, to: destination("with"), options: CloneOptions(recurseSubmodules: true))
        try await Repository.clone(url: sourceURL, to: destination("without"))

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination("with") + "/modules/library/file.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination("without") + "/modules/library/file.txt"))
    }

    func testCancellingStopsGitAndRemovesTheFolder() async throws {
        // The clone is served by an upload-pack that records its pid and then blocks on a FIFO nobody writes, so git is still running when the cancellation arrives, however fast the machine. `git clone` ignores `remote.origin.uploadpack` from `-c`; only `--upload-pack` reaches the transport.
        let started = base.appendingPathComponent("upload-pack.pid")
        let gate = base.appendingPathComponent("gate")
        XCTAssertEqual(mkfifo(gate.path, 0o600), 0)
        let blockingUploadPack = base.appendingPathComponent("blocking-upload-pack")
        try "#!/bin/sh\necho $$ > '\(started.path).tmp' && mv '\(started.path).tmp' '\(started.path)'\nexec cat '\(gate.path)'\n".write(to: blockingUploadPack, atomically: true, encoding: .utf8)
        let blockingGit = base.appendingPathComponent("blocking-git")
        try "#!/bin/sh\nfor argument; do shift; set -- \"$@\" \"$argument\"; [ \"$argument\" = clone ] && set -- \"$@\" '--upload-pack=\(blockingUploadPack.path)'; done\nexec git \"$@\"\n".write(to: blockingGit, atomically: true, encoding: .utf8)
        for script in [blockingUploadPack, blockingGit] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path) }
        let target = destination("cancelled")
        let url = sourceURL!

        let clone = Task { try await Repository.clone(url: url, to: target, gitPath: blockingGit.path) }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: started.path), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let uploadPack = try XCTUnwrap(pid_t(String(contentsOf: started, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)), "git never reached the upload-pack")
        let cancelledAt = Date()
        clone.cancel()
        let result = await clone.result

        XCTAssertThrowsError(try result.get())
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
        // The upload-pack is in git's process group; once orphaned it is reaped by launchd, which may lag a moment.
        let reapDeadline = Date().addingTimeInterval(5)
        while kill(uploadPack, 0) == 0, Date() < reapDeadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotEqual(kill(uploadPack, 0), 0, "the upload-pack git started survived the cancellation")
    }

    func testBadURLFailsWithoutLeavingAFolder() async throws {
        let target = destination("missing")

        do {
            try await Repository.clone(url: base.appendingPathComponent("nothing.git").absoluteString, to: target)
            XCTFail("clone of a missing repository succeeded")
        } catch let error as GitError {
            XCTAssertTrue(error.stderr.contains("does not appear to be a git repository") || error.stderr.contains("not found"), error.stderr)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testFolderWithContentIsRefusedAndKept() async throws {
        let target = destination("occupied")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try "mine\n".write(toFile: target + "/notes.txt", atomically: true, encoding: .utf8)

        do {
            try await Repository.clone(url: sourceURL, to: target)
            XCTFail("clone into a folder with content succeeded")
        } catch is GitError {}
        XCTAssertEqual(try String(contentsOfFile: target + "/notes.txt", encoding: .utf8), "mine\n")
    }

    /// Finder leaves `.DS_Store` in folders it shows; git counts it as content, so the destination check must too.
    func testFolderWithOnlyFinderMetadataIsOccupiedAsGitSees() async throws {
        let target = destination("finder")
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: target + "/.DS_Store"))
        XCTAssertEqual(FolderDestination.at(target), .occupiedFolder)
        XCTAssertEqual(FolderDestination.at(destination("absent")), .missing)

        do {
            try await Repository.clone(url: sourceURL, to: target)
            XCTFail("git cloned into a folder holding .DS_Store")
        } catch is GitError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + "/.DS_Store"))
    }

    // MARK: Parsing

    func testParsesProgressLinesWithCarriageReturns() {
        let output = "Cloning into 'x'...\nremote: Enumerating objects: 12, done.\nremote: Counting objects:  50% (6/12)\rremote: Counting objects: 100% (12/12), done.\nReceiving objects:  33% (4/12)\rReceiving objects: 100% (12/12), 1.20 KiB | 1.20 MiB/s, done.\nResolving deltas: 100% (2/2), done.\nUpdating files:  50% (1/2)\r"

        XCTAssertEqual(CloneProgress.parse(output), [
            CloneProgress(phase: .counting, completed: 6, total: 12),
            CloneProgress(phase: .counting, completed: 12, total: 12),
            CloneProgress(phase: .receiving, completed: 4, total: 12),
            CloneProgress(phase: .receiving, completed: 12, total: 12),
            CloneProgress(phase: .resolving, completed: 2, total: 2),
            CloneProgress(phase: .updatingFiles, completed: 1, total: 2),
        ])
    }

    func testRecognizesCloneSourcesAndTheirNames() throws {
        let names = [
            "https://github.com/owner/project.git": "project",
            "https://gitlab.example.com/group/sub/tool/": "tool",
            "git@github.com:owner/project.git": "project",
            "ssh://git@host:2222/srv/repos/app.git": "app",
            sourceURL!: "origin",
            source.path: "work",
        ]
        for (source, name) in names {
            XCTAssertTrue(CloneSource.isCloneable(source), source)
            XCTAssertEqual(CloneSource.repositoryName(of: source), name, source)
        }
        for text in ["hello world", "just-text", "https://github.com", "/no/such/folder", ""] {
            XCTAssertFalse(CloneSource.isCloneable(text), text)
        }
    }

    func testAuthenticationFailuresAreNamed() {
        let https = "Cloning into 'x'...\nfatal: could not read Username for 'https://github.com': terminal prompts disabled\n"
        let ssh = "Cloning into 'x'...\ngit@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.\n"
        XCTAssertEqual(GitFailure(output: https), .authenticationFailed)
        XCTAssertEqual(GitFailure(output: ssh), .authenticationFailed)
    }

    /// An offline fetch is told apart from a remote that is wrong, so it can be a quiet note instead of a sheet.
    func testUnreachableHostsAreNamed() {
        let https = "fatal: unable to access 'https://example.invalid/x.git/': Could not resolve host: example.invalid\n"
        let ssh = "ssh: connect to host example.com port 22: Operation timed out\nfatal: Could not read from remote repository.\n"
        let refused = "fatal: unable to access 'https://localhost:9/x.git/': Failed to connect to localhost port 9 after 0 ms: Couldn't connect to server\n"
        let missing = "fatal: '/no/such/repo' does not appear to be a git repository\nfatal: Could not read from remote repository.\n"
        XCTAssertEqual(GitFailure(output: https), .unreachable)
        XCTAssertEqual(GitFailure(output: ssh), .unreachable)
        XCTAssertEqual(GitFailure(output: refused), .unreachable)
        XCTAssertEqual(GitFailure(output: missing), .message("'/no/such/repo' does not appear to be a git repository"))
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [CloneProgress] = []

    func add(_ progress: CloneProgress) {
        lock.lock()
        reports.append(progress)
        lock.unlock()
    }

    var all: [CloneProgress] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }
}
