import AppKit

/// Darstellung: light, dark or the system's choice, applied to every window at once, and the interface language, applied on the next launch.
final class AppearanceSettingsViewController: SettingsPaneController {
    private var buttons: [AppSettings.Appearance: NSButton] = [:]
    private var languageButtons: [AppLanguage.Choice: NSButton] = [:]

    override func buildForm(_ form: SettingsForm) {
        for (index, appearance) in AppSettings.Appearance.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: Self.title(of: appearance), target: self, action: #selector(choose(_:)))
            button.state = appearance == AppSettings.appearance ? .on : .off
            buttons[appearance] = button
            form.addRow(index == 0 ? LocalizedStringResource("settings.appearance.colorScheme.label", defaultValue: "Color scheme", bundle: .module, comment: "Settings label of the light, dark or system choice.") : nil, button)
        }
        for (index, language) in AppLanguage.Choice.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: Self.title(of: language), target: self, action: #selector(chooseLanguage(_:)))
            button.state = language == AppSettings.language ? .on : .off
            languageButtons[language] = button
            form.addRow(index == 0 ? LocalizedStringResource("settings.appearance.language.label", defaultValue: "Language", bundle: .module, comment: "Settings label of the interface language choice.") : nil, button)
        }
        form.addCaption(SettingsForm.caption(LocalizedStringResource("settings.appearance.language.caption", defaultValue: "Takes effect the next time GitBonsai starts.", bundle: .module)))
    }

    private static func title(of appearance: AppSettings.Appearance) -> String {
        switch appearance {
        case .system: String(localized: "settings.appearance.colorScheme.system", defaultValue: "System", bundle: .module, comment: "Appearance that follows the system.")
        case .light: String(localized: "settings.appearance.colorScheme.light", defaultValue: "Light", bundle: .module, comment: "Light appearance.")
        case .dark: String(localized: "settings.appearance.colorScheme.dark", defaultValue: "Dark", bundle: .module, comment: "Dark appearance.")
        }
    }

    /// Each language is named in itself, so it can be found whatever the interface shows now.
    private static func title(of language: AppLanguage.Choice) -> String {
        switch language {
        case .system: String(localized: "settings.appearance.language.system", defaultValue: "System Language", bundle: .module, comment: "Interface language that follows the system's language order.")
        case .de: "Deutsch"
        case .en: "English"
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let appearance = buttons.first(where: { $0.value === sender })?.key else { return }
        AppSettings.appearance = appearance
    }

    @objc private func chooseLanguage(_ sender: NSButton) {
        guard let language = languageButtons.first(where: { $0.value === sender })?.key else { return }
        AppSettings.language = language
    }
}
