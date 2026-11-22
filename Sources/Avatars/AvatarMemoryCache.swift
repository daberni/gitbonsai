/// At most `capacity` values; inserting beyond it drops the one used longest ago.
public struct AvatarMemoryCache<Value> {
    public let capacity: Int
    private var entries: [String: (value: Value, used: Int)] = [:]
    private var clock = 0

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }

    /// The value under `key`, which counts as a use.
    public mutating func value(for key: String) -> Value? {
        guard let entry = entries[key] else { return nil }
        clock += 1
        entries[key] = (entry.value, clock)
        return entry.value
    }

    /// Eviction scans all entries, which only happens when a new picture arrives, not per drawn row.
    public mutating func insert(_ value: Value, for key: String) {
        clock += 1
        entries[key] = (value, clock)
        guard entries.count > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key else { return }
        entries[oldest] = nil
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
