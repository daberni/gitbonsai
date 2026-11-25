import Foundation

/// The app's shared date formatters, in the app language.
@MainActor
enum DateText {
    /// "5 minutes ago" in the history, the detail panel and the toolbar.
    static func relative(_ date: Date) -> String {
        fullRelative.localizedString(for: date, relativeTo: Date())
    }

    /// "5 min. ago" in the narrower lists of panels and the ref picker.
    static func shortRelative(_ date: Date) -> String {
        shortRelativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    /// The exact date in tooltips.
    static func exact(_ date: Date) -> String {
        exactFormatter.string(from: date)
    }

    private static let fullRelative = relativeFormatter(.full)
    private static let shortRelativeFormatter = relativeFormatter(.short)

    private static func relativeFormatter(_ style: RelativeDateTimeFormatter.UnitsStyle) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = style
        formatter.locale = AppLanguage.locale
        return formatter
    }

    private static let exactFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        // A pattern per language rather than a template, so the German pattern stays exactly the one the history has always shown.
        formatter.dateFormat = String(localized: "history.row.dateFormat", defaultValue: "EEE, MMM d, yyyy, HH:mm", bundle: .module, comment: "Date format pattern (Unicode/ICU) for a commit's exact date in tooltips")
        return formatter
    }()
}
