import Foundation
import SwiftTreeSitter

/// What a highlighted stretch of text is; the viewer gives each kind a colour from the design tokens.
public enum SyntaxToken: Sendable, Hashable, CaseIterable {
    case keyword, string, comment, number, type, function, constant, property, attribute, tag, `operator`, punctuation, escape, heading, link, inserted, deleted

    /// Maps a highlight capture such as `function.method.builtin` by its leading names; captures without a colour of their own (variables, plain text) give nil.
    init?(capture components: [String]) {
        guard let first = components.first else { return nil }
        switch first {
        case "keyword", "conditional", "repeat", "include", "import", "exception", "storageclass": self = .keyword
        case "string", "character":
            self = components.contains("escape") ? .escape : components.contains("regex") || components.contains("regexp") ? .escape : .string
        case "comment", "spell": self = .comment
        case "number", "float", "boolean": self = .number
        case "type", "constructor", "module", "namespace", "class": self = .type
        case "function", "method": self = .function
        case "constant": self = components.contains("builtin") ? .keyword : .constant
        case "property", "field", "label": self = .property
        case "attribute", "decorator": self = .attribute
        case "tag": self = .tag
        case "operator": self = .operator
        case "punctuation", "delimiter": self = .punctuation
        case "escape", "embedded": self = .escape
        case "text":
            if components.contains("title") { self = .heading } else if components.contains("uri") || components.contains("reference") { self = .link } else if components.contains("literal") { self = .string } else { return nil }
        case "markup":
            if components.contains("heading") { self = .heading } else if components.contains("link") { self = .link } else if components.contains("raw") { self = .string } else { return nil }
        case "diff":
            if components.contains("plus") { self = .inserted } else if components.contains("minus") { self = .deleted } else { return nil }
        case "variable":
            guard components.contains("builtin") else { return nil }
            self = .keyword
        default: return nil
        }
    }
}

/// A highlighted stretch of the document, as a UTF-16 range.
public struct SyntaxSpan: Sendable, Hashable {
    public let range: NSRange
    public let token: SyntaxToken

    public init(range: NSRange, token: SyntaxToken) {
        self.range = range
        self.token = token
    }
}

/// The document parsed once off the main thread; highlights are queried for a range at a time, the range in view, so a large file costs only what is shown.
public actor SyntaxHighlighter {
    /// Larger files show as plain text: parsing them costs more than colour is worth.
    public static let maximumLength = 4 * 1024 * 1024

    private let tree: Tree
    private let query: Query
    private let text: String

    private init(tree: Tree, query: Query, text: String) {
        self.tree = tree
        self.query = query
        self.text = text
    }

    /// Parses the document; nil when the language has no grammar here, the file is over the limit or the grammar fails to load.
    public static func make(for document: TextDocument, language: SyntaxLanguage?) async -> SyntaxHighlighter? {
        guard let language, document.length <= maximumLength else { return nil }
        let text = document.text
        guard let query = try? language.query() else { return nil }
        let parser = Parser()
        guard (try? parser.setLanguage(Language(language.grammar))) != nil, let parsed = parser.parse(text), let tree = parsed.copy() else { return nil }
        return SyntaxHighlighter(tree: tree, query: query, text: text)
    }

    /// Spans inside `range`, less specific ones first so a more specific capture of the same text wins when they are applied in order.
    public func spans(in range: NSRange) -> [SyntaxSpan] {
        guard let root = tree.rootNode else { return [] }
        let cursor = query.execute(node: root, in: tree)
        cursor.setRange(range)
        let matches = Array(cursor.resolve(with: Predicate.Context(string: text)))
        return matches.highlights().compactMap { highlight in
            guard let token = SyntaxToken(capture: highlight.nameComponents) else { return nil }
            return SyntaxSpan(range: highlight.range, token: token)
        }
    }
}
