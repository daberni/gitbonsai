import Foundation

/// The files an interactive rebase started by the app keeps next to git's own state: the todo list, the prepared messages, the two editor scripts and what the branches pointed at before.
///
/// git asks for the todo list through `GIT_SEQUENCE_EDITOR` and for commit messages through `GIT_EDITOR`. Both point at small `/bin/sh` scripts here instead of a helper mode of the app:
/// they work for every program that uses the engine (app and tests), need no path to the app binary, and stay valid while a stopped rebase waits, across app updates and restarts.
/// The message script looks at the last line of git's `done` file, which names the todo line git has just run, and writes the message prepared for that commit; for any other commit it leaves git's text untouched, as `GIT_EDITOR=true` would. Neither script ever opens an editor.
/// The folder lives in the worktree's own git directory (`git rev-parse --git-path gitbonsai-rebase`), so each worktree has its own.
struct RebaseSession {
    let directory: URL
    /// git's `rebase-merge` folder of the same worktree, whose `done` file the message script reads.
    let rebaseDirectory: URL

    var todoFile: URL { directory.appendingPathComponent("todo") }
    var messagesDirectory: URL { directory.appendingPathComponent("messages", isDirectory: true) }
    var sequenceEditor: URL { directory.appendingPathComponent("sequence-editor.sh") }
    var messageEditor: URL { directory.appendingPathComponent("message-editor.sh") }
    var stateFile: URL { directory.appendingPathComponent("state.json") }
    /// What a finished rebase left to undo; it outlives the rest of the session until the next rebase or the undo.
    var undoFile: URL { directory.appendingPathComponent("undo.json") }

    var exists: Bool { FileManager.default.fileExists(atPath: messageEditor.path) }

    /// The environment for `git rebase` and for continuing or skipping it.
    var environment: [String: String] {
        [
            "GIT_SEQUENCE_EDITOR": Self.shellQuoted(sequenceEditor.path),
            "GIT_EDITOR": Self.shellQuoted(messageEditor.path),
        ]
    }

    /// Writes a fresh session for `plan`, replacing one left over from an earlier rebase.
    func create(for plan: RebasePlan, state: RebaseUndo) throws {
        let files = FileManager.default
        try? files.removeItem(at: directory)
        try files.createDirectory(at: messagesDirectory, withIntermediateDirectories: true)
        try Data(plan.todoText.utf8).write(to: todoFile)
        for (sha, message) in plan.editorMessages {
            try Data(message.utf8).write(to: messagesDirectory.appendingPathComponent(sha))
        }
        try write(script: Self.sequenceEditorScript(todo: todoFile.path), to: sequenceEditor)
        try write(script: Self.messageEditorScript(done: rebaseDirectory.appendingPathComponent("done").path, messages: messagesDirectory.path), to: messageEditor)
        try JSONEncoder().encode(state).write(to: stateFile)
    }

    func readState() -> RebaseUndo? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(RebaseUndo.self, from: data)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Ends the session of a finished rebase and keeps only its undo record.
    func finish(with undo: RebaseUndo?) {
        remove()
        guard let undo, let data = try? JSONEncoder().encode(undo), (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        try? data.write(to: undoFile)
    }

    func readUndo() -> RebaseUndo? {
        guard let data = try? Data(contentsOf: undoFile) else { return nil }
        return try? JSONDecoder().decode(RebaseUndo.self, from: data)
    }

    private func write(script: String, to url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func sequenceEditorScript(todo: String) -> String {
        """
        #!/bin/sh
        # GitBonsai: hands git the todo list the app prepared.
        cat \(shellQuoted(todo)) > "$1"

        """
    }

    static func messageEditorScript(done: String, messages: String) -> String {
        """
        #!/bin/sh
        # GitBonsai: supplies the message prepared for the step git has just run; never opens an editor.
        file="$1"
        done_file=\(shellQuoted(done))
        messages=\(shellQuoted(messages))
        [ -f "$done_file" ] || exit 0
        last=""
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                ''|'#'*) ;;
                *) last="$line" ;;
            esac
        done < "$done_file"
        set -f
        set -- $last
        [ $# -ge 2 ] || exit 0
        shift
        case "$1" in -C|-c) shift ;; esac
        sha="$1"
        case "$sha" in */*|.*|'') exit 0 ;; esac
        if [ -f "$messages/$sha" ]; then
            cat "$messages/$sha" > "$file"
        fi
        exit 0

        """
    }

    /// Single quotes keep spaces and every other character literal; a single quote itself is closed, escaped and reopened.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Where a finished interactive rebase started, so that it can be undone: the branch and the stacked branches it moved, each with its place before and after.
public struct RebaseUndo: Sendable, Equatable, Codable {
    public struct Move: Sendable, Equatable, Codable {
        public let ref: String
        public let before: String
        public var after: String?

        public init(ref: String, before: String, after: String?) {
            self.ref = ref
            self.before = before
            self.after = after
        }
    }

    /// The current branch as a full ref name, or nil for a detached HEAD.
    public let branch: String?
    public let before: String
    /// HEAD once the rebase has finished; nil while it still runs.
    public var after: String?
    /// Other branches `--update-refs` was asked to move.
    public var stacked: [Move]

    public init(branch: String?, before: String, after: String?, stacked: [Move]) {
        self.branch = branch
        self.before = before
        self.after = after
        self.stacked = stacked
    }

    public var shortBranch: String? { branch.map { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : $0 } }
}
