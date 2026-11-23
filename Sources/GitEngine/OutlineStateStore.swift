import Foundation

/// Which sections and folders of an outline, such as the sidebar, are collapsed, and which sections it has seen.
/// A section it has seen keeps the user's choice; only a new one takes its default.
public struct OutlineState: Codable, Equatable, Sendable {
    public var collapsed: Set<String>
    public var known: Set<String>

    public init(collapsed: Set<String> = [], known: Set<String> = []) {
        self.collapsed = collapsed
        self.known = known
    }
}

/// Keeps an `OutlineState` per repository path in user defaults. Saving drops the states of repositories that are no longer known, so the entry does not grow forever.
public struct OutlineStateStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, key: String) {
        self.defaults = defaults
        self.key = key
    }

    private var all: [String: OutlineState] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: OutlineState].self, from: $0) } ?? [:]
    }

    public func state(for path: String) -> OutlineState? {
        all[path]
    }

    /// Stores `state` for `path` and keeps the others only when their path is in `known`.
    public func save(_ state: OutlineState, for path: String, keepingOnly known: Set<String>) {
        var states = all.filter { known.contains($0.key) }
        states[path] = state
        defaults.set(try? JSONEncoder().encode(states), forKey: key)
    }
}
