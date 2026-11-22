import Foundation

/// Output of a `--format` that ends each record with `%x1e` (or `%1e`) and separates fields with `%x1f`. git puts a newline after every record, which is dropped.
enum FieldRecords {
    /// The fields of each record. With `limit`, the last field keeps any further separators, for a free-text field such as a message body.
    static func parse(_ data: Data, limit: Int = .max) -> [[String]] {
        data.split(separator: 0x1E).map { record in
            record.drop { $0 == 0x0A }.split(separator: 0x1F, maxSplits: limit - 1, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        }
    }
}
