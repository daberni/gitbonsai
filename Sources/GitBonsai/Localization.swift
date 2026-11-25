import Foundation

/// Marks names inside localized UI copy: `"Rebase \(RefName.branch(name)) onto \(RefName.branch(onto))"`.
/// A marked name is an ordinary `%@` argument for the String Catalog, so a translation may move it; `RefString` finds the mark again and draws the name as a pill.
/// Marked text belongs in a `LocalizedStringResource` that is shown through `RefString`; in a plain `String(localized:)` the marks would show up as stray characters.
enum RefName {
    static func branch(_ name: String) -> String { mark(name, .branch) }
    static func remoteBranch(_ name: String) -> String { mark(name, .remoteBranch) }
    static func remote(_ name: String) -> String { mark(name, .remote) }
    static func tag(_ name: String) -> String { mark(name, .tag) }
    /// A commit is always named by its short SHA.
    static func commit(_ id: String) -> String { mark(String(id.prefix(RefString.shortSHA)), .commit) }
    static func path(_ path: String) -> String { mark(path, .path) }
    static func worktree(_ name: String) -> String { mark(name, .worktree) }
    static func stash(_ name: String) -> String { mark(name, .stash) }

    /// Several paths as one argument, each its own pill, one per line or separated by `separator`.
    static func paths(_ paths: [String], separator: String) -> String {
        paths.map(path).joined(separator: separator)
    }

    static let start: Character = "\u{E000}"
    static let end: Character = "\u{E001}"

    static func mark(_ name: String, _ kind: RefKind) -> String {
        "\(start)\(kind.rawValue)\(name)\(end)"
    }
}

extension LocalizedStringResource.BundleDescription {
    /// The app's resource bundle, for `LocalizedStringResource(…, bundle: .module)`: SwiftPM's `Bundle.module` is a `Bundle`, not a `BundleDescription`.
    static var module: Self { .atURL(Bundle.module.bundleURL) }
}

extension LocalizedStringResource {
    /// The text in the app's language, with its names still marked. Every resource of the app names `bundle: .module`; with the default `.main` the lookup would find no strings when SwiftPM builds the app.
    var marked: String { String(localized: self) }

    /// The text in the app's language as plain text, names included without pills.
    var text: String { RefString(self).plain }

    /// Text that is shown as it is, such as git's output, a commit subject or text already localized and put together elsewhere.
    static func verbatim(_ text: String) -> LocalizedStringResource {
        LocalizedStringResource("common.verbatim", defaultValue: "\(text)", bundle: .module, comment: "Shown as is: git output, a commit subject or text localized elsewhere. Never translated.")
    }

    /// Text built from a `RefString`, for an API that takes a resource; its names stay pills.
    static func verbatim(_ text: RefString) -> LocalizedStringResource { verbatim(text.marked) }
}

/// The language the interface shows and the locale its dates and numbers follow.
enum AppLanguage {
    /// What the settings offer; `system` follows the order of languages in the system settings.
    enum Choice: String, CaseIterable {
        case system, de, en
    }

    /// The catalog's localization the user prefers: the system's language order, or the app's `AppleLanguages` when the settings or a launch argument chose one.
    static let code: String = Bundle.module.preferredLocalizations.first ?? "en"

    /// The user's locale (region, clock, calendar) with the interface's language, so an English interface on a German system says "5 minutes ago" and still uses the 24-hour clock.
    static let locale: Locale = {
        var components = Locale.Components(locale: .autoupdatingCurrent)
        components.languageComponents = Locale.Language.Components(languageCode: Locale.LanguageCode(code))
        return Locale(components: components)
    }()

    /// Runs this launch in `language` without storing anything. Must run before the first string is looked up.
    static func override(_ language: String) {
        UserDefaults.standard.setVolatileDomain(["AppleLanguages": [language]], forName: UserDefaults.argumentDomain)
    }
}
