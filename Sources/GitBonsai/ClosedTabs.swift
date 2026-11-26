import Foundation

/// The repository tabs closed in this run, most recent last, for Reopen closed tab.
/// Kept in memory only: the saved session already restores the open tabs, and a stack from an earlier run would mostly hold stale entries.
struct ClosedTabs {
    struct Entry: Equatable {
        let path: String
        /// The tab's place when it was closed.
        let index: Int
    }

    static let limit = 20
    private(set) var entries: [Entry] = []

    /// A path closed again moves to the top instead of being stacked twice.
    mutating func push(path: String, index: Int) {
        entries.removeAll { $0.path == path }
        entries.append(Entry(path: path, index: index))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Removes and returns the most recent entry whose folder still exists; entries passed over on the way are dropped.
    mutating func pop(exists: (String) -> Bool = ClosedTabs.folderExists) -> Entry? {
        while let entry = entries.popLast() {
            if exists(entry.path) { return entry }
        }
        return nil
    }

    func reopenableCount(exists: (String) -> Bool = ClosedTabs.folderExists) -> Int {
        entries.filter { exists($0.path) }.count
    }

    static func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
