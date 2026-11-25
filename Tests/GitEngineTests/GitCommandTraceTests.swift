import XCTest
@testable import GitEngine

/// The log line of a git call names the subcommand in the clear and never carries a credential from a URL.
final class GitCommandTraceTests: XCTestCase {
    func testSubcommandSkipsOptionsAndTheirValues() {
        XCTAssertEqual(GitCommandTrace.subcommand(of: ["-c", "core.quotepath=off", "-C", "/repo", "--no-pager", "log", "--format=%H"]), "log")
        XCTAssertEqual(GitCommandTrace.subcommand(of: ["--version"]), "git")
    }

    func testCredentialsInURLsAreRemoved() {
        let arguments = ["clone", "--", "https://alice:s3cret@github.com/org/repo.git", "/tmp/a@b"]
        XCTAssertEqual(GitCommandTrace.redacted(arguments), ["clone", "--", "https://***@github.com/org/repo.git", "/tmp/a@b"])
        XCTAssertEqual(GitCommandTrace.redacted(["fetch", "git@github.com:org/repo.git"]), ["fetch", "git@github.com:org/repo.git"])
    }
}
