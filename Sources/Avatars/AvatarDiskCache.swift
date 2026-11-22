import CryptoKit
import Foundation

/// Avatars and the knowledge that someone has none, one file per lookup, valid for a limited time.
///
/// A found picture stays longer than a miss, so a newly uploaded avatar shows up within days.
/// `sweep` removes what expired and keeps the folder under `maxBytes`; `removeAll` deletes the folder.
public struct AvatarDiskCache: Sendable {
    public enum Entry: Sendable, Equatable {
        case image(Data)
        case missing
    }

    public let directory: URL
    public let imageLifetime: TimeInterval
    public let missingLifetime: TimeInterval
    public let maxBytes: Int

    public init(directory: URL, imageLifetime: TimeInterval = 7 * 86_400, missingLifetime: TimeInterval = 3 * 86_400, maxBytes: Int = 50_000_000) {
        self.directory = directory
        self.imageLifetime = imageLifetime
        self.missingLifetime = missingLifetime
        self.maxBytes = maxBytes
    }

    /// The entry stored under `key`; nil when there is none or it expired. Expired files are removed.
    public func read(_ key: String, now: Date) -> Entry? {
        let files = self.files(for: key)
        let manager = FileManager.default
        for (url, lifetime, isImage) in [(files.image, imageLifetime, true), (files.missing, missingLifetime, false)] {
            guard let date = (try? manager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            guard now.timeIntervalSince(date) < lifetime, now >= date.addingTimeInterval(-60) else {
                try? manager.removeItem(at: url)
                continue
            }
            if !isImage { return .missing }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            return .image(data)
        }
        return nil
    }

    public func write(_ entry: Entry, for key: String, now: Date) {
        let files = self.files(for: key)
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let (url, other, data): (URL, URL, Data) = switch entry {
        case .image(let data): (files.image, files.missing, data)
        case .missing: (files.missing, files.image, Data())
        }
        try? manager.removeItem(at: other)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        try? manager.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    /// Removes expired entries, then the oldest until the folder holds at most `maxBytes`. Files the cache did not write are left alone.
    public func sweep(now: Date) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var kept: [(url: URL, date: Date, size: Int)] = []
        for url in urls {
            let lifetime: TimeInterval
            switch url.pathExtension {
            case "img": lifetime = imageLifetime
            case "none": lifetime = missingLifetime
            default: continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) >= lifetime || now < date.addingTimeInterval(-60) {
                try? manager.removeItem(at: url)
            } else {
                kept.append((url, date, values?.fileSize ?? 0))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for entry in kept.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? manager.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// File names are hashes, so no address appears on disk.
    private func files(for key: String) -> (image: URL, missing: URL) {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return (directory.appendingPathComponent(name + ".img"), directory.appendingPathComponent(name + ".none"))
    }
}
