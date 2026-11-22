import Foundation
import XCTest
@testable import GitEngine

extension Repository {
    func collectLog(_ options: LogOptions = LogOptions()) async throws -> [Commit] {
        var commits: [Commit] = []
        for try await commit in log(options) { commits.append(commit) }
        return commits
    }
}

extension FixtureRepo {
    var repository: Repository { Repository(path: path) }
}
