import Foundation

/// Groups branch names by their first path segment and orders folders and plain branches together, strictly by name, as one list.
public enum BranchTree {
    public enum Entry<Item> {
        /// A folder such as `bugfix/` with its branches, named without the folder and sorted by name.
        case folder(String, [(name: String, item: Item)])
        case branch(String, Item)

        /// The name the entry sorts by: a folder without its trailing slash, so `bugfix/` sits where `bugfix` would.
        var sortName: String {
            switch self {
            case .folder(let name, _): String(name.dropLast())
            case .branch(let name, _): name
            }
        }
    }

    /// `items` with the names they are shown under; a name with a slash goes into the folder of its first segment.
    public static func entries<Item>(_ items: [(name: String, item: Item)]) -> [Entry<Item>] {
        var folders: [String: [(name: String, item: Item)]] = [:]
        var result: [Entry<Item>] = []
        for (name, item) in items {
            if let slash = name.firstIndex(of: "/") {
                folders[String(name[...slash]), default: []].append((String(name[name.index(after: slash)...]), item))
            } else {
                result.append(.branch(name, item))
            }
        }
        for (folder, children) in folders {
            result.append(.folder(folder, children.sorted { precedes($0.name, $1.name) }))
        }
        return result.sorted { precedes($0.sortName, $1.sortName) }
    }

    /// Finder's order: case-insensitive, numbers by value.
    static func precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
