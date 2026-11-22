import Foundation
import XCTest

/// Guards the String Catalog: every key translated, every key the code uses present, and no user-facing literal outside the catalog.
/// The literal scan is a heuristic over the source text (no type information); `LiteralScanner` lists what it can and cannot see.
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let appSources = root.appendingPathComponent("Sources/GitBonsaiApp")
    private static let catalogURL = appSources.appendingPathComponent("Resources/Localizable.xcstrings")

    func testEveryKeyHasACompleteGermanTranslation() throws {
        let catalog = try Catalog(url: Self.catalogURL)
        var problems: [String] = []
        for (key, entry) in catalog.entries.sorted(by: { $0.key < $1.key }) {
            if entry.isStale { problems.append("stale, no longer in the code: \(key)") }
            guard entry.shouldTranslate else { continue }
            guard let german = entry.values(for: "de"), !german.isEmpty else {
                problems.append("no German: \(key)")
                continue
            }
            let expected = Catalog.placeholders(in: key)
            for value in german where !Catalog.placeholders(in: value).isSubset(of: expected) {
                problems.append("German placeholders differ from the key: \(key) → \(value)")
            }
        }
        XCTAssert(problems.isEmpty, "Localizable.xcstrings (run scripts/sync-strings.sh, then translate):\n" + problems.joined(separator: "\n"))
    }

    func testKeysAreEnglishSourceText() throws {
        let catalog = try Catalog(url: Self.catalogURL)
        let german = catalog.entries.keys.filter { LiteralScanner.looksGerman($0) && !LiteralScanner.allowed.contains($0) }
        XCTAssert(german.isEmpty, "Keys are the English source text; these look German:\n" + german.sorted().joined(separator: "\n"))
    }

    /// Compares the catalog with what the compiler extracted in the last build. Skips when no build output is there, for example on a clean checkout that only built the tests.
    func testCatalogMatchesTheKeysTheCodeUses() throws {
        let used = try ExtractedKeys.load(root: Self.root)
        guard !used.isEmpty else { throw XCTSkip("No .stringsdata of GitBonsaiApp under .build/out; build the app first.") }
        let catalog = try Catalog(url: Self.catalogURL)
        let missing = used.subtracting(catalog.entries.keys).sorted()
        let unused = Set(catalog.entries.keys).subtracting(used).sorted()
        XCTAssert(missing.isEmpty, "Used in the code but not in Localizable.xcstrings (run scripts/sync-strings.sh):\n" + missing.joined(separator: "\n"))
        XCTAssert(unused.isEmpty, "In Localizable.xcstrings but no longer used (delete them):\n" + unused.joined(separator: "\n"))
    }

    func testNoUserFacingLiteralOutsideTheCatalog() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.appSources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let findings = try files.flatMap { try LiteralScanner.findings(in: $0) }
        XCTAssert(findings.isEmpty, "User-facing text must go through String(localized:bundle:) or a LocalizedStringResource (or LiteralScanner.allowed):\n" + findings.joined(separator: "\n"))
    }

    func testScannerCatchesTypicalMistakes() {
        let bad = [
            #"button.title = "Abbrechen""#,
            #"let label = NSTextField(labelWithString: "Remote branch")"#,
            #"item.toolTip = "Shows the diff""#,
            #"alert.addButton(withTitle: "Delete")"#,
            #"let text = "\(count) Dateien geändert""#,
            #"let title = String(localized: "Fetch")"#,
            #"let title = String(localized: "Check out \(RefName.branch(name))", bundle: .module)"#,
            #"keywords: ["checkout", "auschecken"],"#,
        ]
        let good = [
            #"button.title = String(localized: "Cancel", bundle: .module)"#,
            #"ActionMenuItem("Rename…") { }"#,
            #"let note = "git merge""#,
            #"keywords: "checkout, switch","#,
            #"field.placeholderString = "feature/…""#,
            #"print("Gewechselt")"#,
        ]
        for line in bad { XCTAssertFalse(LiteralScanner.findings(inLine: line).isEmpty, line) }
        for line in good { XCTAssertTrue(LiteralScanner.findings(inLine: line).isEmpty, line) }
    }
}

/// The parts of `Localizable.xcstrings` the checks need.
struct Catalog {
    struct Entry {
        let json: [String: Any]

        var isStale: Bool { json["extractionState"] as? String == "stale" }
        var shouldTranslate: Bool { json["shouldTranslate"] as? Bool ?? true }

        /// Every value of a language: the string, or each plural variant. Nil when the language has no translated value.
        func values(for language: String) -> [String]? {
            guard let localization = (json["localizations"] as? [String: Any])?[language] as? [String: Any] else { return nil }
            if let unit = localization["stringUnit"] as? [String: Any] {
                guard unit["state"] as? String == "translated", let value = unit["value"] as? String else { return nil }
                return [value]
            }
            guard let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] else { return nil }
            var values: [String] = []
            for case let variant as [String: Any] in plural.values {
                guard let unit = variant["stringUnit"] as? [String: Any], unit["state"] as? String == "translated", let value = unit["value"] as? String else { return nil }
                values.append(value)
            }
            return values.isEmpty ? nil : values
        }
    }

    let entries: [String: Entry]

    init(url: URL) throws {
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = json?["strings"] as? [String: [String: Any]] ?? [:]
        entries = strings.mapValues(Entry.init)
    }

    /// The format specifiers of a text as their kind, positional ones by position: a translation may reorder or, in a plural variant, drop them, but never add one.
    static func placeholders(in text: String) -> Set<String> {
        let pattern = /%(?:(\d+)\$)?(@|lld|ld|d)/
        var result: Set<String> = []
        var position = 0
        for match in text.replacingOccurrences(of: "%%", with: "").matches(of: pattern) {
            position += 1
            let index = match.output.1.map { Int($0) ?? position } ?? position
            result.insert("\(index):\(match.output.2)")
        }
        return result
    }
}

/// The keys the compiler extracted from `String(localized:)` and `LocalizedStringResource` literals in the last build of the app.
enum ExtractedKeys {
    static func load(root: URL) throws -> Set<String> {
        let intermediates = root.appendingPathComponent(".build/out/Intermediates.noindex/GitBonsai.build")
        guard let enumerator = FileManager.default.enumerator(at: intermediates, includingPropertiesForKeys: nil) else { return [] }
        var keys: Set<String> = []
        for case let url as URL in enumerator where url.pathExtension == "stringsdata" && url.path.contains("/GitBonsaiApp") && url.path.contains("/Debug/") {
            // The build writes them as JSON; xcstringstool may write binary property lists.
            let data = try Data(contentsOf: url)
            let plist = try (try? JSONSerialization.jsonObject(with: data)) ?? PropertyListSerialization.propertyList(from: data, format: nil)
            let tables = (plist as? [String: Any])?["tables"] as? [String: [[String: Any]]] ?? [:]
            for entry in tables["Localizable"] ?? [] {
                if let key = entry["key"] as? String { keys.insert(key) }
            }
        }
        return keys
    }
}

/// A pragmatic scan of the app's string literals for text that bypasses the catalog. It flags
/// - any literal that looks German (umlauts, ß or common German words), wherever it is, since the code is written in English;
/// - an English-looking literal (a capital letter, then letters) handed straight to an AppKit text sink such as `title =`, `stringValue =`, `toolTip =`, `labelWithString:` or `withTitle:`;
/// - `String(localized:)` without `bundle:` (it would look in the empty main bundle) or with `RefName` marks (they need `RefString`).
/// It cannot see: English text passed to a `String` parameter of the app's own types, text built in variables before it reaches a sink, literals split over lines, or German without the listed signals.
/// Lines of `print` and `FileHandle.standardError` and everything after `//` are skipped; harness files may report in any language, but their comparisons with titles still face the sink rule.
enum LiteralScanner {
    /// Literals that look like copy but are not translated: names of languages in themselves, product and app names, git terms shown as they are.
    static let allowed: Set<String> = ["Deutsch", "English", "GitBonsai", "Detached HEAD", "HEAD"]

    static let sinks = [
        "title =", "stringValue =", "toolTip =", "placeholderString =", "messageText =", "informativeText =", "prompt =", "message =",
        "labelWithString:", "wrappingLabelWithString:", "withTitle:", "checkboxWithTitle:", "radioButtonWithTitle:", "NSMenuItem(title:", "NSMenu(title:",
        "setAccessibilityLabel(", "accessibilityDescription:", "setAccessibilityTitle(", "NSButton(title:",
    ]

    private static let germanWords: Set<String> = [
        "und", "nicht", "kein", "keine", "der", "die", "das", "den", "dem", "ist", "wird", "werden", "auf", "mit", "von", "zu", "für", "noch", "nach", "alle", "alles",
        "auschecken", "löschen", "anlegen", "öffnen", "schließen", "ändern", "zurück", "bearbeiten", "verwerfen", "umbenennen", "hinzufügen", "entfernen", "wählen", "abbrechen",
        "fehlgeschlagen", "geändert", "lokal", "lokale", "datei", "dateien", "ordner", "nachricht", "einstellungen", "neuer", "neue", "neues", "zum", "zur", "beim",
    ]

    static func looksGerman(_ text: String) -> Bool {
        if text.contains(where: { "äöüÄÖÜß„".contains($0) }) { return true }
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter })
        return words.contains { germanWords.contains(String($0)) }
    }

    static func findings(in file: URL) throws -> [String] {
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        // The harness's reports are diagnostics for whoever runs it, not interface text; its comparisons with titles still have to be localized.
        let diagnostics = file.lastPathComponent.hasPrefix("ScreenshotHarness")
        return lines.enumerated().flatMap { index, line in
            findings(inLine: line, diagnostics: diagnostics).map { "\(file.lastPathComponent):\(index + 1): \($0)" }
        }
    }

    static func findings(inLine rawLine: String, diagnostics: Bool = false) -> [String] {
        let line = codePart(of: rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("print(") || trimmed.contains("FileHandle.standardError") || trimmed.hasPrefix("///") { return [] }
        var result: [String] = []
        if line.contains("String(localized:") && !line.contains("bundle:") { result.append("String(localized:) without bundle: .module") }
        if line.contains("String(localized:") && line.contains("RefName.") { result.append("RefName marks inside String(localized:); use RefString") }
        for (literal, prefix) in literals(in: line) {
            if allowed.contains(literal) { continue }
            let localized = prefix.contains("String(localized:") || prefix.contains("LocalizedStringResource(")
            if looksGerman(literal) && !diagnostics {
                result.append("German-looking literal \"\(literal)\"")
            } else if !localized, looksLikeCopy(literal), let sink = sinks.first(where: { prefix.hasSuffix($0) || prefix.hasSuffix($0 + " ") }) {
                result.append("literal \"\(literal)\" passed to \(sink)")
            }
        }
        return result
    }

    /// A capital letter followed by a lowercase letter: a word of copy, not an identifier, key, path or command.
    private static func looksLikeCopy(_ text: String) -> Bool {
        let letters = Array(text)
        guard letters.count >= 2, letters[0].isUppercase, letters[1].isLowercase else { return false }
        return !text.contains("/") && !text.hasPrefix("git ")
    }

    /// The line without a trailing `//` comment, ignoring `//` inside literals.
    private static func codePart(of line: String) -> String {
        var inString = false
        var previous: Character = " "
        for (offset, character) in line.enumerated() {
            if character == "\"" && previous != "\\" { inString.toggle() }
            if !inString && character == "/" && previous == "/" { return String(line.prefix(offset - 1)) }
            previous = character
        }
        return line
    }

    /// Each single-line literal with the code before it, interpolations included in the literal's text.
    private static func literals(in line: String) -> [(String, String)] {
        var result: [(String, String)] = []
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            guard characters[index] == "\"" else {
                index += 1
                continue
            }
            let prefix = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
            var end = index + 1
            var depth = 0
            while end < characters.count {
                if characters[end] == "\\" && end + 1 < characters.count && characters[end + 1] == "(" {
                    depth += 1
                    end += 2
                    continue
                }
                if depth > 0 && characters[end] == ")" { depth -= 1 }
                if characters[end] == "\\" {
                    end += 2
                    continue
                }
                if depth == 0 && characters[end] == "\"" { break }
                end += 1
            }
            result.append((String(characters[(index + 1)..<min(end, characters.count)]), prefix))
            index = end + 1
        }
        return result
    }
}
