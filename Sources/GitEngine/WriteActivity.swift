import Foundation
import Synchronization

/// When the app itself last wrote to a working tree, so the file watcher can tell the app's own writes from outside changes.
/// The action that wrote refreshes on its own; the file events it causes must not refresh a second time.
public enum WriteActivity {
    /// What the app is writing: anything a write command may touch, or only the index, which reads that compare the working tree with it may rewrite.
    public enum Kind: Sendable {
        case write
        case indexRefresh
    }

    struct Entry {
        var running = 0
        var began = Date.distantPast
        var ended = Date.distantPast

        func covers(from first: Date, to last: Date, settle: TimeInterval) -> Bool {
            guard first >= began else { return false }
            return running > 0 || last <= ended.addingTimeInterval(settle)
        }
    }

    private static let entries = Mutex<[String: [Kind: Entry]]>([:])

    static func began(_ path: String, _ kind: Kind = .write) {
        let key = RealPath.of(path)
        entries.withLock { entries in
            entries[key, default: [:]][kind, default: Entry()].running += 1
            entries[key]?[kind]?.began = Date()
        }
    }

    static func ended(_ path: String, _ kind: Kind = .write) {
        let key = RealPath.of(path)
        entries.withLock { entries in
            entries[key, default: [:]][kind, default: Entry()].running -= 1
            entries[key]?[kind]?.ended = Date()
        }
    }

    /// True when every moment from `first` to `last` falls into a write of the app on `path`, or into the `settle` time after it in which its file events still arrive.
    /// A burst that touched only the index (`indexOnly`) is also covered by the app's index-refreshing reads; any other file changed meanwhile is someone else's.
    public static func covers(_ path: String, from first: Date, to last: Date, settle: TimeInterval, indexOnly: Bool = false) -> Bool {
        let key = RealPath.of(path)
        guard let kinds = entries.withLock({ $0[key] }) else { return false }
        if kinds[.write]?.covers(from: first, to: last, settle: settle) == true { return true }
        return indexOnly && kinds[.indexRefresh]?.covers(from: first, to: last, settle: settle) == true
    }
}

/// The path with every link resolved, as git records it and FSEvents reports it: `/tmp/x` becomes `/private/tmp/x`, which Foundation's `resolvingSymlinksInPath` would turn back.
/// A path that does not exist is only standardized.
public enum RealPath {
    public static func of(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
