import Foundation

/// A diff line as it is drawn: plain text, faint markers that stand in for invisible characters, and badges that name them.
/// Control characters and line separators always become markers or badges, so no byte git passes through can break a line's layout; the rest shows only with `showsInvisibles`.
public enum DiffLineText {
    public struct Run: Sendable, Hashable {
        public enum Kind: Sendable, Hashable {
            case text
            /// A faint glyph in place of a character: `→` for a tab, `·` for a trailing space, a control picture such as `␍` or `␀`.
            case marker
            /// A capsule with a name such as `BOM`, `NBSP` or `ZWSP` for a character without a glyph of its own.
            case badge
        }

        public let kind: Kind
        public let text: String
        /// Inside the changed part of a changed line pair.
        public let emphasized: Bool

        public init(kind: Kind, text: String, emphasized: Bool = false) {
            self.kind = kind
            self.text = text
            self.emphasized = emphasized
        }
    }

    public struct Options: Sendable, Hashable {
        public var showsInvisibles: Bool
        /// Tabs and trailing spaces are marked in added and removed lines only.
        public var isChanged: Bool
        /// The first line of a file, where U+FEFF is a byte order mark.
        public var isFileStart: Bool
        /// Draw `␍` at the end, for a line that ended with CR LF.
        public var marksCarriageReturn: Bool
        /// The line ending differs from the paired line's.
        public var carriageReturnEmphasized: Bool
        /// The changed part, in Unicode scalars of the line's text.
        public var emphasis: Range<Int>?
        public var tabWidth: Int

        public init(showsInvisibles: Bool, isChanged: Bool = false, isFileStart: Bool = false, marksCarriageReturn: Bool = false, carriageReturnEmphasized: Bool = false, emphasis: Range<Int>? = nil, tabWidth: Int = 4) {
            self.showsInvisibles = showsInvisibles
            self.isChanged = isChanged
            self.isFileStart = isFileStart
            self.marksCarriageReturn = marksCarriageReturn
            self.carriageReturnEmphasized = carriageReturnEmphasized
            self.emphasis = emphasis
            self.tabWidth = tabWidth
        }
    }

    /// Characters that take no room or look like a space, named the way editors name them.
    static let invisibleNames: [UInt32: String] = [
        0x00A0: "NBSP",
        0x00AD: "SHY",
        0x180E: "MVS",
        0x2007: "FIGSP",
        0x200B: "ZWSP",
        0x200C: "ZWNJ",
        0x200D: "ZWJ",
        0x200E: "LRM",
        0x200F: "RLM",
        0x202A: "LRE",
        0x202B: "RLE",
        0x202C: "PDF",
        0x202D: "LRO",
        0x202E: "RLO",
        0x202F: "NNBSP",
        0x2060: "WJ",
        0x2066: "LRI",
        0x2067: "RLI",
        0x2068: "FSI",
        0x2069: "PDI",
        0xFEFF: "ZWNBSP",
    ]

    /// Characters that end a line or a paragraph for AppKit; they never reach the text drawing.
    static let lineBreakNames: [UInt32: String] = [
        0x2028: "LSEP",
        0x2029: "PSEP",
    ]

    public static func runs(_ text: String, options: Options) -> [Run] {
        let scalars = Array(text.unicodeScalars)
        let marksWhitespace = options.showsInvisibles && options.isChanged
        let trailingStart = marksWhitespace ? (scalars.lastIndex { $0 != " " && $0 != "\t" }.map { $0 + 1 } ?? 0) : scalars.count
        var builder = Builder()
        for (index, scalar) in scalars.enumerated() {
            let emphasized = options.emphasis?.contains(index) ?? false
            let value = scalar.value
            if scalar == "\t" {
                if marksWhitespace {
                    builder.append(.marker, "→", emphasized)
                    builder.append(.text, String(repeating: " ", count: max(0, options.tabWidth - 1)), emphasized)
                } else {
                    builder.append(.text, String(repeating: " ", count: options.tabWidth), emphasized)
                }
            } else if scalar == " ", index >= trailingStart {
                builder.append(.marker, "·", emphasized)
            } else if value < 0x20 {
                builder.append(.marker, String(Character(Unicode.Scalar(0x2400 + value)!)), emphasized)
            } else if value == 0x7F {
                builder.append(.marker, "␡", emphasized)
            } else if (0x80...0x9F).contains(value) {
                builder.append(.badge, String(format: "U+%04X", value), emphasized)
            } else if let name = lineBreakNames[value] {
                builder.append(.badge, name, emphasized)
            } else if value == 0xFEFF, index == 0, options.isFileStart {
                if options.showsInvisibles { builder.append(.badge, "BOM", emphasized) }
            } else if let name = invisibleNames[value], options.showsInvisibles {
                builder.append(.badge, name, emphasized)
            } else {
                builder.append(.text, String(scalar), emphasized)
            }
        }
        if options.marksCarriageReturn { builder.append(.marker, "␍", options.carriageReturnEmphasized) }
        return builder.runs
    }

    /// Monospaced columns the runs take, with a badge counted as its name plus room for the capsule.
    public static func columns(of runs: [Run]) -> Int {
        runs.reduce(0) { $0 + $1.text.count + ($1.kind == .badge ? 2 : 0) }
    }

    /// Joins neighbouring scalars of the same kind and emphasis; badges stay one run each.
    private struct Builder {
        var runs: [Run] = []

        mutating func append(_ kind: Run.Kind, _ text: String, _ emphasized: Bool) {
            if kind != .badge, let last = runs.last, last.kind == kind, last.emphasized == emphasized {
                runs[runs.count - 1] = Run(kind: kind, text: last.text + text, emphasized: emphasized)
            } else {
                runs.append(Run(kind: kind, text: text, emphasized: emphasized))
            }
        }
    }
}

/// The changed part of a removed line and the added line paired with it, for intraline highlighting.
public struct IntralineChange: Sendable, Hashable {
    /// The scalars between the common prefix and suffix of both texts; nil when the texts are equal or share nothing.
    public let range: Range<Int>?
    /// One line ends with CR LF and the other does not.
    public let lineEndingChanged: Bool
}

public enum IntralineDiff {
    /// Pairs each block of removed lines with the added lines right after it, line by line in order, and returns the change of every paired line by its index in `lines`.
    /// Only common prefix and suffix are compared, which is linear in the line length and enough to point at a single changed character.
    public static func changes(in lines: [DiffLine]) -> [Int: IntralineChange] {
        var result: [Int: IntralineChange] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else { index += 1; continue }
            let removedStart = index
            while index < lines.count, lines[index].kind == .removed { index += 1 }
            let addedStart = index
            while index < lines.count, lines[index].kind == .added { index += 1 }
            let pairs = min(addedStart - removedStart, index - addedStart)
            for offset in 0..<pairs {
                let old = lines[removedStart + offset]
                let new = lines[addedStart + offset]
                let (oldRange, newRange) = changedRanges(Array(old.text.unicodeScalars), Array(new.text.unicodeScalars))
                let endingChanged = old.carriageReturn != new.carriageReturn
                result[removedStart + offset] = IntralineChange(range: oldRange, lineEndingChanged: endingChanged)
                result[addedStart + offset] = IntralineChange(range: newRange, lineEndingChanged: endingChanged)
            }
        }
        return result
    }

    static func changedRanges(_ old: [Unicode.Scalar], _ new: [Unicode.Scalar]) -> (Range<Int>?, Range<Int>?) {
        guard old != new else { return (nil, nil) }
        let shorter = min(old.count, new.count)
        var prefix = 0
        while prefix < shorter, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        // Lines with nothing in common are simply replaced; marking all of them adds nothing.
        guard prefix + suffix > 0 else { return (nil, nil) }
        let oldRange = prefix..<(old.count - suffix)
        let newRange = prefix..<(new.count - suffix)
        return (oldRange.isEmpty ? nil : oldRange, newRange.isEmpty ? nil : newRange)
    }
}

public enum LineEnding: String, Sendable, Hashable {
    case lf = "LF"
    case crlf = "CRLF"
}

public extension FileDiff {
    /// Every line of the file changed only its line ending, as after a conversion between LF and CR LF; one notice says so instead of a marker on each line.
    var lineEndingConversion: (from: LineEnding, to: LineEnding)? {
        let lines = hunks.flatMap(\.lines)
        // A last line without a newline has no ending to convert and stays context.
        guard lines.allSatisfy({ $0.kind != .context || $0.missingNewline }) else { return nil }
        let removed = lines.filter { $0.kind == .removed }
        let added = lines.filter { $0.kind == .added }
        guard !removed.isEmpty, removed.count == added.count else { return nil }
        guard let oldEnding = removed.first?.carriageReturn, let newEnding = added.first?.carriageReturn, oldEnding != newEnding else { return nil }
        let uniform = zip(removed, added).allSatisfy { old, new in
            let lastLine = old.missingNewline || new.missingNewline
            return old.text == new.text && (lastLine || (old.carriageReturn == oldEnding && new.carriageReturn == newEnding))
        }
        guard uniform else { return nil }
        return (oldEnding ? .crlf : .lf, newEnding ? .crlf : .lf)
    }
}

/// A text encoding git does not read as text: UTF-16 and UTF-32 contain NUL bytes, so git calls such files binary.
public enum WideTextEncoding: Sendable, Hashable {
    case utf16LE(bom: Bool)
    case utf16BE(bom: Bool)
    case utf32LE
    case utf32BE

    public var name: String {
        switch self {
        case .utf16LE: "UTF-16 LE"
        case .utf16BE: "UTF-16 BE"
        case .utf32LE: "UTF-32 LE"
        case .utf32BE: "UTF-32 BE"
        }
    }

    /// The value for `working-tree-encoding` in `.gitattributes` that lets git store the file as UTF-8 and diff it as text.
    public var workingTreeEncoding: String {
        switch self {
        case .utf16LE(let bom): bom ? "UTF-16LE-BOM" : "UTF-16LE"
        case .utf16BE(let bom): bom ? "UTF-16BE-BOM" : "UTF-16BE"
        case .utf32LE: "UTF-32LE"
        case .utf32BE: "UTF-32BE"
        }
    }

    /// Recognises the encoding by its byte order mark, or for UTF-16 without one by ASCII text whose every other byte is NUL.
    public static func detect(_ data: Data) -> WideTextEncoding? {
        let bytes = [UInt8](data.prefix(4096))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LE }
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BE }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16LE(bom: true) }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BE(bom: true) }
        let pairs = bytes.count / 2
        guard pairs >= 2 else { return nil }
        let evens = stride(from: 0, to: pairs * 2, by: 2).map { bytes[$0] }
        let odds = stride(from: 1, to: pairs * 2, by: 2).map { bytes[$0] }
        func isText(_ byte: UInt8) -> Bool { byte == 0x09 || byte == 0x0A || byte == 0x0D || (0x20..<0x7F).contains(byte) }
        // Mostly ASCII text on one side and NUL on the other; a few non-Latin characters may break the pattern.
        let threshold = pairs * 9 / 10
        if odds.filter({ $0 == 0 }).count >= threshold, evens.filter(isText).count >= threshold { return .utf16LE(bom: false) }
        if evens.filter({ $0 == 0 }).count >= threshold, odds.filter(isText).count >= threshold { return .utf16BE(bom: false) }
        return nil
    }
}
