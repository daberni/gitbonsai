import Foundation
@testable import GitEngine

/// A repository with every menu subject: main checked out with three commits and an upstream, feature with its own commit and upstream, other checked out in a second worktree, a tag and a stash.
struct MenuFixtureRepo {
    let repo: FixtureRepo
    let origin: FixtureRepo
    let root: String
    let tagged: String
    let head: String
    let feature: String
    let worktreePath: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("gitbonsai-menus-\(UUID().uuidString)", isDirectory: true)
        origin = try FixtureRepo(at: base.appendingPathComponent("origin.git"))
        try origin.git("config", "receive.denyCurrentBranch", "ignore")
        repo = try FixtureRepo(at: base.appendingPathComponent("repo"))
        root = try repo.commit("c1", file: "one.txt")
        tagged = try repo.commit("c2", file: "two.txt")
        head = try repo.commit("c3", file: "three.txt")
        try repo.git("remote", "add", "origin", origin.path)
        try repo.git("push", "-q", "-u", "origin", "main")
        try repo.git("tag", "v1", tagged)
        try repo.git("switch", "-q", "-c", "feature", root)
        feature = try repo.commit("f1", file: "feature.txt")
        try repo.git("push", "-q", "-u", "origin", "feature")
        try repo.git("switch", "-q", "main")
        try repo.git("branch", "other")
        worktreePath = base.appendingPathComponent("wt").path
        try repo.git("worktree", "add", "-q", worktreePath, "other")
        try repo.write("one.txt", "changed\n")
        try repo.git("stash", "-q")
    }

    func remove() {
        try? FileManager.default.removeItem(at: repo.url.deletingLastPathComponent())
    }
}
