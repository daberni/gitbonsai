import Foundation

extension Repository {
    /// Writes git's commit-graph file once when the repository has none, so `git log --topo-order` can stream the first commits at once instead of walking the whole history first.
    ///
    /// Only git's own maintenance runs (`git commit-graph write --reachable`, as `git gc` does); afterwards `git gc`, `git maintenance` and `fetch.writeCommitGraph` keep the file current.
    /// Skipped when `core.commitGraph` or `gc.writeCommitGraph` is false, and when an `index.lock` shows another git operation at work. Returns whether it wrote the file.
    @discardableResult
    public func writeCommitGraphIfMissing() async -> Bool {
        guard await configValue("core.commitGraph", type: "bool") != "false", await configValue("gc.writeCommitGraph", type: "bool") != "false" else { return false }
        let paths = ["objects/info/commit-graph", "objects/info/commit-graphs/commit-graph-chain", "index.lock"]
        guard let result = try? await runner.run(["rev-parse", "--path-format=absolute"] + paths.flatMap { ["--git-path", $0] }) else { return false }
        let resolved = result.stdoutString.split(separator: "\n").map(String.init)
        guard resolved.count == paths.count, !resolved.contains(where: { FileManager.default.fileExists(atPath: $0) }) else { return false }
        // The graph lives under objects, which the file watcher ignores; git takes its own commit-graph.lock, and a failure only leaves the history as slow as before.
        return (try? await runner.runWithoutIndex(["commit-graph", "write", "--reachable"])) != nil
    }
}
