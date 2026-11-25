import Foundation
import XCTest

/// Guards the String Catalog: semantic keys, English and German for every key, the code's English equal to the catalog's, no duplicated meaning, and no user-facing literal outside the catalog.
/// The literal scan is a heuristic over the source text (no type information); `LiteralScanner` lists what it can and cannot see.
final class LocalizationTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let appSources = root.appendingPathComponent("Sources/GitBonsai")
    private static let catalogURL = appSources.appendingPathComponent("Resources/Localizable.xcstrings")

    func testKeysFollowTheScheme() throws {
        let catalog = try Catalog(url: Self.catalogURL)
        let outside = catalog.entries.keys.filter { !Catalog.followsScheme($0) }.sorted()
        XCTAssert(outside.isEmpty, "Keys are dotted lowerCamelCase segments starting with one of the areas in AGENTS.md (\(Catalog.areas.sorted().joined(separator: ", "))):\n" + outside.joined(separator: "\n"))
    }

    func testEveryKeyHasEnglishAndGerman() throws {
        let catalog = try Catalog(url: Self.catalogURL)
        var problems: [String] = []
        for (key, entry) in catalog.entries.sorted(by: { $0.key < $1.key }) {
            if entry.isStale { problems.append("stale, no longer in the code: \(key)") }
            guard entry.shouldTranslate else { continue }
            let english = entry.values(for: "en", requireTranslated: false) ?? []
            if english.isEmpty { problems.append("no English: \(key)") }
            for value in english where LiteralScanner.looksGerman(value) && !LiteralScanner.allowed.contains(value) {
                problems.append("English looks German: \(key) → \(value)")
            }
            guard let german = entry.values(for: "de"), !german.isEmpty else {
                problems.append(entry.hasLocalization("de") ? "German needs review (the English changed): \(key)" : "no German: \(key)")
                continue
            }
            let expected = english.reduce(into: Set<String>()) { $0.formUnion(Catalog.placeholders(in: $1)) }
            for value in german where !Catalog.placeholders(in: value).isSubset(of: expected) {
                problems.append("German placeholders differ from the English: \(key) → \(value)")
            }
        }
        XCTAssert(problems.isEmpty, "Localizable.xcstrings (run scripts/sync-strings.sh, then translate):\n" + problems.joined(separator: "\n"))
    }

    /// Compares the catalog with what the compiler extracted in the last build. Skips when no build output is there, for example on a clean checkout that only built the tests.
    func testCatalogMatchesTheKeysTheCodeUses() throws {
        let extracted = try ExtractedKeys.load(root: Self.root)
        guard !extracted.isEmpty else { throw XCTSkip("No .stringsdata of GitBonsai under .build/out; build the app first.") }
        let catalog = try Catalog(url: Self.catalogURL)
        let used = Set(extracted.keys)
        let missing = used.subtracting(catalog.entries.keys).sorted()
        let unused = Set(catalog.entries.keys).subtracting(used).sorted()
        XCTAssert(missing.isEmpty, "Used in the code but not in Localizable.xcstrings (run scripts/sync-strings.sh):\n" + missing.joined(separator: "\n"))
        XCTAssert(unused.isEmpty, "In Localizable.xcstrings but no longer used (delete them):\n" + unused.joined(separator: "\n"))
    }

    /// The `defaultValue` in the code is what a reader takes for the English text, so it has to be the catalog's English; a plural key matches its `other` variant.
    func testEnglishInTheCodeMatchesTheCatalog() throws {
        let extracted = try ExtractedKeys.load(root: Self.root)
        guard !extracted.isEmpty else { throw XCTSkip("No .stringsdata of GitBonsai under .build/out; build the app first.") }
        let catalog = try Catalog(url: Self.catalogURL)
        var problems: [String] = []
        for (key, values) in extracted.sorted(by: { $0.key < $1.key }) {
            guard let entry = catalog.entries[key], entry.shouldTranslate else { continue }
            let english = entry.sourceValue.map(Catalog.positionless)
            for value in values {
                guard let value else {
                    problems.append("no defaultValue in the code: \(key)")
                    continue
                }
                if Catalog.positionless(value) != english { problems.append("\(key): code says “\(value)”, catalog says “\(english ?? "nothing")”") }
            }
        }
        XCTAssert(problems.isEmpty, "English in the code and in Localizable.xcstrings differ (run scripts/sync-strings.sh, then review the German):\n" + problems.joined(separator: "\n"))
    }

    /// One meaning, one key. Whether two texts mean the same is not machine-readable, so two cheap rules stand in for it:
    /// a text that a `common.` key already holds must use that key, and two keys of the same screen (`area.screen`) never share a text.
    /// The same text elsewhere is allowed: a toolbar label and a command title may need different translations later, which is why the keys are semantic.
    /// Texts count as equal only when English and German both match; a different German proves a different meaning.
    func testNoDuplicatedMeaning() throws {
        let catalog = try Catalog(url: Self.catalogURL)
        let texts = catalog.entries.filter { $0.value.shouldTranslate }.compactMapValues(\.fingerprint)
        let byText = Dictionary(grouping: texts.keys, by: { texts[$0]! })
        var problems: [String] = []
        for keys in byText.values where keys.count > 1 {
            let sorted = keys.sorted()
            if let common = sorted.first(where: { $0.hasPrefix("common.") }) {
                problems += sorted.filter { $0 != common }.map { "\($0) repeats \(common); use the common key" }
            }
            let byScreen = Dictionary(grouping: sorted, by: Catalog.screen)
            for (screen, same) in byScreen where same.count > 1 && !screen.hasPrefix("common.") {
                problems.append("same text on one screen: " + same.joined(separator: ", "))
            }
        }
        XCTAssert(problems.isEmpty, "Duplicated meanings in Localizable.xcstrings:\n" + problems.sorted().joined(separator: "\n"))
    }

    func testNoUserFacingLiteralOutsideTheCatalog() throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.appSources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let findings = try files.flatMap { try LiteralScanner.findings(in: $0) }
        XCTAssert(findings.isEmpty, "User-facing text must go through String(localized:defaultValue:bundle:) or LocalizedStringResource(_:defaultValue:bundle:) (or LiteralScanner.allowed):\n" + findings.joined(separator: "\n"))
    }

    func testSchemeRejectsTypicalMistakes() {
        for key in ["commit.menu.reset", "toolbar.pull.title", "settings.general.editors.label", "failure.pull.uncommittedChanges", "common.copySHA"] {
            XCTAssertTrue(Catalog.followsScheme(key), key)
        }
        for key in ["Reset", "commit menu reset", "Commit.menu.reset", "commit.Menu.reset", "commit.menu.", "commit", "commit..reset", "unknownArea.menu.reset", "commit.menu.reset…"] {
            XCTAssertFalse(Catalog.followsScheme(key), key)
        }
    }

    func testScannerCatchesTypicalMistakes() {
        let bad = [
            #"button.title = "Abbrechen""#,
            #"let label = NSTextField(labelWithString: "Remote branch")"#,
            #"item.toolTip = "Shows the diff""#,
            #"alert.addButton(withTitle: "Delete")"#,
            #"let text = "\(count) Dateien geändert""#,
            #"let title = String(localized: "toolbar.fetch.title", defaultValue: "Fetch")"#,
            #"let title = String(localized: "toolbar.fetch.title", bundle: .module)"#,
            #"let title = String(localized: "branch.menu.checkout", defaultValue: "Check out \(RefName.branch(name))", bundle: .module)"#,
            #"ActionMenuItem(LocalizedStringResource("branch.menu.rename", defaultValue: "Rename…"))"#,
            #"keywords: ["checkout", "auschecken"],"#,
        ]
        let good = [
            #"button.title = String(localized: "common.cancel", defaultValue: "Cancel", bundle: .module)"#,
            #"ActionMenuItem(LocalizedStringResource("branch.menu.rename", defaultValue: "Rename…", bundle: .module)) { }"#,
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

        func hasLocalization(_ language: String) -> Bool { localization(language) != nil }

        /// Every value of a language: the string, or each plural variant. Nil when the language has no value, or with `requireTranslated` one that is not marked translated
        /// (English that xcstringstool took from the code is "new"; German becomes "needs_review" when that English changes).
        func values(for language: String, requireTranslated: Bool = true) -> [String]? {
            guard let localization = localization(language) else { return nil }
            func value(of unit: Any?) -> String? {
                guard let unit = unit as? [String: Any], !requireTranslated || unit["state"] as? String == "translated" else { return nil }
                return unit["value"] as? String
            }
            if localization["stringUnit"] != nil { return value(of: localization["stringUnit"]).map { [$0] } }
            guard let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: Any] else { return nil }
            var values: [String] = []
            for case let variant as [String: Any] in plural.values {
                guard let text = value(of: variant["stringUnit"]) else { return nil }
                values.append(text)
            }
            return values.isEmpty ? nil : values
        }

        /// The English the code has to give as `defaultValue`: the string, or the `other` variant of a plural.
        var sourceValue: String? {
            guard let english = localization("en") else { return nil }
            if let unit = english["stringUnit"] as? [String: Any] { return unit["value"] as? String }
            let other = ((english["variations"] as? [String: Any])?["plural"] as? [String: Any])?["other"] as? [String: Any]
            return (other?["stringUnit"] as? [String: Any])?["value"] as? String
        }

        /// English and German together, to compare two keys' texts.
        var fingerprint: String? {
            guard let english = values(for: "en", requireTranslated: false), let german = values(for: "de") else { return nil }
            return english.sorted().joined(separator: "\u{1}") + "\u{2}" + german.sorted().joined(separator: "\u{1}")
        }

        private func localization(_ language: String) -> [String: Any]? {
            (json["localizations"] as? [String: Any])?[language] as? [String: Any]
        }
    }

    /// The first segment of every key; AGENTS.md says what each is for.
    static let areas: Set<String> = [
        "common", "menu", "window", "welcome", "repository", "toolbar", "sidebar", "history", "detail", "diff", "files", "commit", "branch", "checkout", "tag", "stash", "worktree",
        "fetch", "pull", "push", "rebase", "operation", "conflict", "clone", "settings", "command", "commandBar", "refPicker", "panel", "failure",
    ]

    /// `area.screen.element`: at least two dotted lowerCamelCase segments, the first one an area.
    static func followsScheme(_ key: String) -> Bool {
        guard key.wholeMatch(of: /[a-z][a-zA-Z0-9]*(\.[a-z][a-zA-Z0-9]*)+/) != nil else { return false }
        return areas.contains(String(key.prefix { $0 != "." }))
    }

    /// The first two segments of a key.
    static func screen(_ key: String) -> String { key.split(separator: ".").prefix(2).joined(separator: ".") }

    /// The text with positional specifiers made plain (`%1$@` → `%@`): xcstringstool writes positions into English that has several arguments.
    static func positionless(_ text: String) -> String { text.replacing(/%\d+\$/, with: "%") }

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

/// The keys the compiler extracted from `String(localized:)` and `LocalizedStringResource` literals in the last build of the app, each with the `defaultValue` of every call site (nil where a site gives none).
enum ExtractedKeys {
    static func load(root: URL) throws -> [String: [String?]] {
        let intermediates = root.appendingPathComponent(".build/out/Intermediates.noindex/GitBonsai.build")
        guard let enumerator = FileManager.default.enumerator(at: intermediates, includingPropertiesForKeys: nil) else { return [:] }
        var keys: [String: [String?]] = [:]
        for case let url as URL in enumerator where url.pathExtension == "stringsdata" && url.path.contains(/\/GitBonsai-[a-z]+\.build\//) && url.path.contains("/Debug/") {
            // The build writes them as JSON; xcstringstool may write binary property lists.
            let data = try Data(contentsOf: url)
            let plist = try (try? JSONSerialization.jsonObject(with: data)) ?? PropertyListSerialization.propertyList(from: data, format: nil)
            let tables = (plist as? [String: Any])?["tables"] as? [String: [[String: Any]]] ?? [:]
            for entry in tables["Localizable"] ?? [] {
                if let key = entry["key"] as? String { keys[key, default: []].append(entry["value"] as? String) }
            }
        }
        return keys
    }
}

/// A pragmatic scan of the app's string literals for text that bypasses the catalog. It flags
/// - any literal that looks German (umlauts, ß or common German words), wherever it is, since the code is written in English;
/// - an English-looking literal (a capital letter, then letters) handed straight to an AppKit text sink such as `title =`, `stringValue =`, `toolTip =`, `labelWithString:` or `withTitle:`;
/// - `String(localized:)` without `defaultValue:` or `bundle:` (it would look in the empty main bundle), or with `RefName` marks (they need `RefString`); `LocalizedStringResource(` without `bundle:`.
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
        return lines.enumerated().flatMap { index, line in
            findings(inLine: line).map { "\(file.lastPathComponent):\(index + 1): \($0)" }
        }
    }

    static func findings(inLine rawLine: String) -> [String] {
        let line = codePart(of: rawLine)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("print(") || trimmed.contains("FileHandle.standardError") || trimmed.hasPrefix("///") { return [] }
        var result: [String] = []
        if line.contains("String(localized: \""), !line.contains("bundle:") { result.append("String(localized:) without bundle: .module") }
        if line.contains("String(localized: \""), !line.contains("defaultValue:") { result.append("String(localized:) without defaultValue:") }
        if line.contains("LocalizedStringResource(\""), !line.contains("bundle:") { result.append("LocalizedStringResource without bundle: .module") }
        if line.contains("String(localized:") && line.contains("RefName.") { result.append("RefName marks inside String(localized:); use RefString") }
        for (literal, prefix) in literals(in: line) {
            if allowed.contains(literal) { continue }
            let localized = prefix.contains("String(localized:") || prefix.contains("LocalizedStringResource(")
            if looksGerman(literal) {
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
