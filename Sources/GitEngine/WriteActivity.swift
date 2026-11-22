import Foundation
import Synchronization

/// When the app itself last wrote to a working tree, so the file watcher can tell the app's own writes from outside changes.
/// The action that wrote refreshes on its own; the file events it causes must not refresh a second time.
public enum WriteActivity {
    struct Entry {
        var running = 0
        var began = Date.distantPast
        var ended = Date.distantPast
    }

    private static let entries = Mutex<[String: Entry]>([:])

    static func began(_ path: String) {
        let key = RealPath.of(path)
        entries.withLock { entries in
            entries[key, default: Entry()].running += 1
            entries[key]?.began = Date()
        }
    }

    static func ended(_ path: String) {
        let key = RealPath.of(path)
        entries.withLock { entries in
            entries[key, default: Entry()].running -= 1
            entries[key]?.ended = Date()
        }
    }

    /// True when every moment from `first` to `last` falls into a write of the app on `path`, or into the `settle` time after it in which its file events still arrive.
    public static func covers(_ path: String, from first: Date, to last: Date, settle: TimeInterval) -> Bool {
        let key = RealPath.of(path)
        guard let entry = entries.withLock({ $0[key] }) else { return false }
        guard first >= entry.began else { return false }
        return entry.running > 0 || last <= entry.ended.addingTimeInterval(settle)
    }
}

/// The path with every symlink resolved the way FSEvents reports it, `/private/tmp` for `/tmp` included.
enum RealPath {
    static func of(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return (path as NSString).standardizingPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
