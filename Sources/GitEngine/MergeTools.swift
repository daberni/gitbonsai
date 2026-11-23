import Foundation

/// The tools `git mergetool` knows and the one the user's global git config names for windowed use (`merge.guitool`), read and written outside any repository.
/// `environment` lets tests point git at their own global config with `GIT_CONFIG_GLOBAL`.
public enum MergeTools {
    public static let guiToolKey = "merge.guitool"

    /// Built-in and user-defined tools, from `git mergetool --tool-help`.
    public static func all(gitPath: String = GitRunner.defaultGitPath(), environment: [String: String] = [:]) async throws -> [MergeTool] {
        let result = try await runner(gitPath).run(["mergetool", "--tool-help"], environment: environment)
        return MergeToolParser.parseToolHelp(result.stdoutString)
    }

    /// `merge.guitool` of the global git config; nil when it is not set.
    public static func globalGuiTool(gitPath: String = GitRunner.defaultGitPath(), environment: [String: String] = [:]) async throws -> String? {
        let result = try await runner(gitPath).run(["config", "--global", "--get", guiToolKey], environment: environment, accepting: [0, 1])
        let name = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Sets `merge.guitool` in the global git config, which `git mergetool --gui` reads in every repository that does not set its own.
    public static func setGlobalGuiTool(_ name: String, gitPath: String = GitRunner.defaultGitPath(), environment: [String: String] = [:]) async throws {
        _ = try await runner(gitPath).runWithoutIndex(["config", "--global", guiToolKey, name], environment: environment)
    }

    private static func runner(_ gitPath: String) -> GitRunner {
        GitRunner(repositoryPath: NSTemporaryDirectory(), gitPath: gitPath)
    }
}
