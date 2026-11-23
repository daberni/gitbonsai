import AppKit

/// What keeps a harness run apart from the user's environment and from other harness runs: its own pasteboard, defaults domain, git configuration and run folder.
@MainActor
extension ScreenshotHarness {
    /// Names the run's own resources; parallel runs never share them.
    static let runID = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"

    /// Copy and paste go through this pasteboard. Harness runs get one of their own, so they never read or change the user's clipboard.
    static var pasteboard: NSPasteboard {
        guard isActive else { return .general }
        return runPasteboard
    }

    private static let runPasteboard = NSPasteboard(name: NSPasteboard.Name("app.gitbonsai.harness.\(runID)"))

    /// Preferences and session state the app keeps. Each harness run gets a fresh domain in its run folder, so recent repositories, modes and layouts never leak between runs or sessions.
    /// `GITBONSAI_DEFAULTS=<name>` shares the domain `app.gitbonsai.harness.<name>` between runs instead, for checks that read what an earlier run stored; it stays after the run.
    static var defaults: UserDefaults {
        guard isActive else { return .standard }
        return runDefaults
    }

    private static let sharedDefaultsName = environment["GITBONSAI_DEFAULTS"].flatMap { $0.isEmpty ? nil : $0 }
    // A suite named by an absolute path keeps its plist there instead of in the user's preferences. A suite is nil only for the main bundle's own identifier.
    private static let runDefaults = UserDefaults(suiteName: sharedDefaultsName.map { "app.gitbonsai.harness.\($0)" } ?? runFolder.appendingPathComponent("defaults").path) ?? .standard

    /// A temporary folder for what the run keeps for itself, removed when it quits.
    static let runFolder: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(runFolderPrefix + runID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    private static let runFolderPrefix = "gitbonsai-harness-"

    /// Removes the run folders of earlier runs that ended without cleaning up, such as after a crash; their name starts with the process identifier.
    static func removeStaleRunFolders() {
        guard isActive else { return }
        let temporary = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        for name in names where name.hasPrefix(runFolderPrefix) {
            let pid = name.dropFirst(runFolderPrefix.count).split(separator: "-").first.flatMap { pid_t($0) }
            guard let pid, pid != ProcessInfo.processInfo.processIdentifier, kill(pid, 0) != 0 else { continue }
            try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
        }
    }

    /// git in a harness run reads a global configuration of the run's own instead of the user's, so commits are never signed with the user's key and the user's aliases, hooks and tools stay out.
    /// git finds the global file through `HOME` and `XDG_CONFIG_HOME`; the runner keeps both and drops inherited `GIT_*` variables, so `GIT_CONFIG_NOSYSTEM` may not reach git and the system file can still apply.
    /// Must run before the first git process starts.
    static func isolateGitConfig() {
        guard isActive else { return }
        let home = runFolder.appendingPathComponent("home", isDirectory: true)
        let config = """
            [user]
            \tname = GitBonsai Harness
            \temail = harness@gitbonsai.invalid
            [commit]
            \tgpgSign = false
            [tag]
            \tgpgSign = false
            [init]
            \tdefaultBranch = main

            """
        try? FileManager.default.createDirectory(at: home.appendingPathComponent(".config", isDirectory: true), withIntermediateDirectories: true)
        try? config.write(to: home.appendingPathComponent(".gitconfig"), atomically: true, encoding: .utf8)
        setenv("HOME", home.path, 1)
        setenv("XDG_CONFIG_HOME", home.appendingPathComponent(".config").path, 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
    }

    /// Removes what the run created for itself; called when the app terminates.
    static func cleanUpRun() {
        guard isActive else { return }
        runPasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: runFolder)
    }
}
