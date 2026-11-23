import CryptoKit
import Foundation

/// What a generated stand-in for a missing avatar is drawn from: the same address always gives the same tint and pattern, in every repository.
public struct AvatarFallback: Sendable, Equatable {
    /// Picks one of the caller's palette colours.
    public let tint: Int
    /// A 5×5 pattern, row by row, mirrored around its middle column.
    public let cells: [Bool]

    public static let side = 5

    /// `email` is normalized first, so case and surrounding spaces do not change the result; text that is no address still gets a stable result.
    public init(email: String, palette: Int) {
        let address = AvatarPlan.normalized(email) ?? email
        let bytes = Array(SHA256.hash(data: Data(address.utf8)))
        tint = palette > 0 ? Int(bytes[0]) % palette : 0
        let half = (Self.side + 1) / 2
        var cells = Array(repeating: false, count: Self.side * Self.side)
        for row in 0..<Self.side {
            for column in 0..<half {
                let bit = row * half + column
                let on = bytes[1 + bit / 8] & (1 << (bit % 8)) != 0
                cells[row * Self.side + column] = on
                cells[row * Self.side + Self.side - 1 - column] = on
            }
        }
        self.cells = cells
    }
}
