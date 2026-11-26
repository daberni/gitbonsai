import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSharp
import TreeSitterCSS
import TreeSitterDiff
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterKotlin
import TreeSitterLess
import TreeSitterMarkdown
import TreeSitterPHP
import TreeSitterPython
import TreeSitterProperties
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSCSS
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterXML
import TreeSitterYAML

/// The languages the viewer highlights, each a tree-sitter grammar compiled into the app with the highlight queries in `Resources/queries`.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case bash, c, cpp, csharp, css, diff, go, html, java, javascript, jsx, json, kotlin, less, markdown, php, properties, python, ruby, rust, scss, swift, tsx, typescript, xml, yaml

    /// The language of a path by its extension or name; nil for anything else, which shows as plain text.
    public init?(path: String) {
        let name = (path as NSString).lastPathComponent.lowercased()
        let pathExtension = (name as NSString).pathExtension
        switch pathExtension {
        case "sh", "bash", "zsh": self = .bash
        case "c", "h": self = .c
        case "cc", "cpp", "cxx", "hh", "hpp", "hxx": self = .cpp
        case "cs": self = .csharp
        case "css": self = .css
        case "diff", "patch": self = .diff
        case "go": self = .go
        case "html", "htm", "xhtml": self = .html
        case "java": self = .java
        case "js", "mjs", "cjs": self = .javascript
        case "jsx": self = .jsx
        case "json", "jsonc", "resolved": self = .json
        case "kt", "kts": self = .kotlin
        case "less": self = .less
        case "md", "markdown": self = .markdown
        case "php": self = .php
        case "properties": self = .properties
        case "py", "pyi": self = .python
        case "rb", "rake", "gemspec": self = .ruby
        case "rs": self = .rust
        case "scss": self = .scss
        case "swift": self = .swift
        case "ts", "mts", "cts": self = .typescript
        case "tsx": self = .tsx
        case "xml", "plist", "svg", "xib", "storyboard", "xsd", "xsl", "xslt", "csproj", "fsproj", "vcxproj", "resx", "xaml", "entitlements": self = .xml
        case "yml", "yaml": self = .yaml
        default:
            switch name {
            case "gemfile", "rakefile", "podfile", "fastfile": self = .ruby
            case ".zshrc", ".bashrc", ".profile": self = .bash
            default: return nil
            }
        }
    }

    var grammar: OpaquePointer {
        switch self {
        case .bash: tree_sitter_bash()
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .csharp: tree_sitter_c_sharp()
        case .css: tree_sitter_css()
        case .diff: tree_sitter_diff()
        case .go: tree_sitter_go()
        case .html: tree_sitter_html()
        case .java: tree_sitter_java()
        case .javascript, .jsx: tree_sitter_javascript()
        case .json: tree_sitter_json()
        case .kotlin: tree_sitter_kotlin()
        case .less: tree_sitter_less()
        case .markdown: tree_sitter_markdown()
        case .php: tree_sitter_php()
        case .properties: tree_sitter_properties()
        case .python: tree_sitter_python()
        case .ruby: tree_sitter_ruby()
        case .rust: tree_sitter_rust()
        case .scss: tree_sitter_scss()
        case .swift: tree_sitter_swift()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .xml: tree_sitter_xml()
        case .yaml: tree_sitter_yaml()
        }
    }

    /// Query files in the order they are joined: a grammar that extends another one (TypeScript, C++) lists the base first, as the grammars' own `inherits` notes say.
    var queryFiles: [String] {
        switch self {
        case .cpp: ["c", "cpp"]
        // The SCSS grammar extends CSS's and its query only adds what SCSS has on top.
        case .scss: ["css", "scss"]
        case .jsx: ["javascript", "jsx"]
        case .typescript: ["javascript", "typescript"]
        case .tsx: ["javascript", "jsx", "typescript"]
        default: [rawValue]
        }
    }

    /// The highlight query, compiled once per language and process.
    func query() throws -> Query {
        try QueryCache.shared.query(for: self)
    }
}

private final class QueryCache: @unchecked Sendable {
    static let shared = QueryCache()
    private let lock = NSLock()
    private var queries: [SyntaxLanguage: Query] = [:]

    func query(for language: SyntaxLanguage) throws -> Query {
        lock.lock()
        defer { lock.unlock() }
        if let query = queries[language] { return query }
        var source = Data()
        for file in language.queryFiles {
            guard let url = Bundle.module.url(forResource: file, withExtension: "scm", subdirectory: "queries") else { throw SyntaxError.missingQuery(file) }
            source.append(try Data(contentsOf: url))
            source.append(0x0A)
        }
        let query = try Query(language: Language(language.grammar), data: source)
        queries[language] = query
        return query
    }
}

enum SyntaxError: Error {
    case missingQuery(String)
}
