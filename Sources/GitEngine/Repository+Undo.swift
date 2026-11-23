import Foundation

/// The refs a local operation moved, recorded before and after it, so that the operation can be undone without asking first: the commits stay reachable, only the refs go back.
public struct UndoPoint: Sendable, Equatable {
    /// How HEAD's branch goes back when the operation moved it: `keep` leaves local changes in place and refuses where they would be overwritten; `soft` and `mixed` undo a reset of that kind exactly.
    public enum HeadRestore: String, Sendable {
        case keep, soft, mixed
    }

    public struct State: Sendable, Equatable {
        /// HEAD's branch as a full ref name, nil when detached.
        public var branch: String?
        public var head: String?
        /// The watched refs that exist, by full name.
        public var refs: [String: String]
    }

    public let watched: [String]
    public let before: State
    public var after: State?
    public let headRestore: HeadRestore

    /// The commands that undo it, for the status line.
    public var commandLine: String {
        guard let after else { return "" }
        var commands: [String] = []
        if before.branch != after.branch {
            commands.append(before.branch.map { "git switch \(Self.short($0))" } ?? "git switch --detach")
        } else if before.head != after.head {
            commands.append("git reset --\(headRestore.rawValue)")
        }
        if watched.contains(where: { !isHeadBranch($0) && before.refs[$0] != after.refs[$0] }) { commands.append("git update-ref --stdin") }
        return commands.joined(separator: " && ")
    }

    /// The branch HEAD stayed on goes back with the reset; after a switch, the branch left behind is an ordinary ref again.
    func isHeadBranch(_ ref: String) -> Bool { before.branch == after?.branch && ref == before.branch }

    static func short(_ ref: String) -> String { ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref }
}

extension Repository {
    /// Records HEAD and `refs` (full names) before a local operation; `finishUndoPoint` records them after it.
    public func undoPoint(watching refs: [String], headRestore: UndoPoint.HeadRestore = .keep) async -> UndoPoint {
        UndoPoint(watched: refs, before: await undoState(refs), after: nil, headRestore: headRestore)
    }

    /// The point with the state the operation left, or nil when it changed nothing.
    public func finishUndoPoint(_ point: UndoPoint) async -> UndoPoint? {
        var point = point
        let after = await undoState(point.watched)
        guard after != point.before else { return nil }
        point.after = after
        return point
    }

    /// True while HEAD and every watched ref are still where the operation left them and no other operation is in progress.
    public func canUndo(_ point: UndoPoint) async -> Bool {
        guard let after = point.after, await operationInProgress() == nil else { return false }
        return await undoState(point.watched) == after
    }

    /// Puts HEAD and the watched refs back where they were before the operation. Local changes stay; git refuses where they would be overwritten.
    public func undo(_ point: UndoPoint) async throws {
        guard let after = point.after, await canUndo(point) else { throw GitError(arguments: ["update-ref"], exitCode: 1, stderr: "The refs have moved since; there is nothing to undo.") }
        let before = point.before
        if before.branch != after.branch {
            if let branch = before.branch {
                _ = try await runner.runWrite(["switch", "--no-guess", UndoPoint.short(branch)])
            } else if let head = before.head {
                _ = try await runner.runWrite(["switch", "--detach", head])
            }
        } else if before.head != after.head, let head = before.head {
            _ = try await runner.runWrite(["reset", "--\(point.headRestore.rawValue)", head])
        }
        let moves = point.watched.filter { !point.isHeadBranch($0) && before.refs[$0] != after.refs[$0] }.map { ref -> String in
            switch (before.refs[ref], after.refs[ref]) {
            case (let old?, let new?): "update \(ref) \(old) \(new)\n"
            case (let old?, nil): "create \(ref) \(old)\n"
            case (nil, let new?): "delete \(ref) \(new)\n"
            case (nil, nil): ""
            }
        }
        guard !moves.isEmpty else { return }
        _ = try await runner.runWrite(["update-ref", "--stdin"], stdin: Data(("start\n" + moves.joined() + "commit\n").utf8))
    }

    private func undoState(_ refs: [String]) async -> UndoPoint.State {
        var resolved: [String: String] = [:]
        for ref in refs {
            if let sha = await resolveCommit(ref) { resolved[ref] = sha }
        }
        return UndoPoint.State(branch: await currentBranchRef(), head: await resolveCommit("HEAD"), refs: resolved)
    }
}
