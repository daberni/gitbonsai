import Foundation

/// A file's text as the viewer shows it: lines joined with LF, so a CR LF ending never shows as a character, and every line's start for line and column lookups.
/// How the bytes were decoded and how lines ended stays on the document, so the viewer can say so instead of hiding it.
public struct TextDocument: Sendable {
    public enum Encoding: Sendable, Equatable {
        case utf8
        /// UTF-8 with a byte order mark, which is not part of the text.
        case utf8WithBOM
        case utf16LittleEndian
        case utf16BigEndian
        /// The bytes are not valid UTF-8 and were read as Windows Latin 1 so every byte shows; the viewer marks the file.
        case fallbackWindowsLatin1

        public var isFallback: Bool { self == .fallbackWindowsLatin1 }
    }

    public enum LineEndings: Sendable, Equatable {
        case lf
        case crlf
        /// Some lines end with CR LF, others with LF.
        case mixed
        /// A single line without an ending says nothing about the file's convention.
        case none
    }

    /// The text shown: lines separated by LF, without a trailing LF for a final newline.
    public let text: String
    /// UTF-16 offset of each line's start in `text`; never empty.
    public let lineStarts: [Int]
    public let encoding: Encoding
    public let lineEndings: LineEndings
    /// The last line has no newline after it.
    public let missingFinalNewline: Bool
    /// UTF-16 length of `text`.
    public let length: Int

    public var lineCount: Int { lineStarts.count }

    /// Builds the document from lines that carry no ending of their own, such as the lines of a diff.
    public init(lines: [String], carriageReturns: Int = 0, missingFinalNewline: Bool = false, encoding: Encoding = .utf8) {
        let endings = missingFinalNewline ? lines.count - 1 : lines.count
        self.init(text: lines.joined(separator: "\n"), lineEndings: Self.lineEndings(endings: endings, carriageReturns: carriageReturns), missingFinalNewline: missingFinalNewline, encoding: encoding)
    }

    /// Decodes a file's bytes: UTF-8 (with or without BOM), UTF-16 with a BOM, otherwise Windows Latin 1 as the fallback that shows every byte.
    /// Works on the UTF-16 units once, since a 100k-line file must open within the budget; only LF ends a line, as for git, and a CR right before it is left out of the text.
    public init(data: Data) {
        let (decoded, encoding) = Self.decode(data)
        var units = Array(decoded.utf16)
        let endsWithNewline = units.last == 0x0A
        if endsWithNewline { units.removeLast() }
        var endings = 0
        var carriageReturns = 0
        var kept = 0
        for index in units.indices {
            let unit = units[index]
            if unit == 0x0A {
                endings += 1
                if kept > 0, units[kept - 1] == 0x0D {
                    carriageReturns += 1
                    kept -= 1
                }
            }
            units[kept] = unit
            kept += 1
        }
        if endsWithNewline {
            endings += 1
            if kept > 0, units[kept - 1] == 0x0D {
                carriageReturns += 1
                kept -= 1
            }
        }
        let text = carriageReturns == 0 && !endsWithNewline ? decoded : String(decoding: units[..<kept], as: UTF16.self)
        self.init(text: text, lineEndings: Self.lineEndings(endings: endings, carriageReturns: carriageReturns), missingFinalNewline: !endsWithNewline && !decoded.isEmpty, encoding: encoding)
    }

    private init(text: String, lineEndings: LineEndings, missingFinalNewline: Bool, encoding: Encoding) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        self.text = text
        length = offset
        lineStarts = starts
        self.lineEndings = lineEndings
        self.missingFinalNewline = missingFinalNewline
        self.encoding = encoding
    }

    private static func lineEndings(endings: Int, carriageReturns: Int) -> LineEndings {
        endings <= 0 ? .none : carriageReturns == 0 ? .lf : carriageReturns >= endings ? .crlf : .mixed
    }

    private static func decode(_ data: Data) -> (String, Encoding) {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return (text, .utf8WithBOM) }
        if bytes.starts(with: [0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return (text, .utf16LittleEndian) }
        if bytes.starts(with: [0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return (text, .utf16BigEndian) }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        return (String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self), .fallbackWindowsLatin1)
    }

    // MARK: Lines and columns

    /// The line that holds a UTF-16 offset; an offset at a line's LF belongs to that line.
    public func line(atOffset offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// The UTF-16 range of a line without its LF.
    public func range(ofLine line: Int) -> NSRange {
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : length
        return NSRange(location: start, length: end - start)
    }

    public func position(atOffset offset: Int) -> TextPosition {
        let line = line(atOffset: offset)
        return TextPosition(line: line, column: offset - lineStarts[line])
    }

    public func offset(of position: TextPosition) -> Int {
        let line = min(max(position.line, 0), lineStarts.count - 1)
        let range = range(ofLine: line)
        return range.location + min(max(position.column, 0), range.length)
    }
}

/// A place in the text: zero-based line and UTF-16 column.
public struct TextPosition: Sendable, Hashable, Comparable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (lhs: TextPosition, rhs: TextPosition) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }
}

/// A selected stretch of text from `start` up to, not including, `end`.
public struct TextSelection: Sendable, Hashable {
    public let start: TextPosition
    public let end: TextPosition

    public init(start: TextPosition, end: TextPosition) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var isEmpty: Bool { start == end }

    /// The lines the selection touches; a selection that ends at the very start of a line leaves that line out, as when whole lines are dragged over.
    public var lines: ClosedRange<Int> {
        let last = end.column == 0 && end.line > start.line ? end.line - 1 : end.line
        return start.line...last
    }
}

extension TextDocument {
    public func selection(of range: NSRange) -> TextSelection {
        TextSelection(start: position(atOffset: range.location), end: position(atOffset: NSMaxRange(range)))
    }
}
