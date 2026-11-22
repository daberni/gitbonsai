import AppKit

/// Darstellung: light, dark or the system's choice, applied to every window at once.
final class AppearanceSettingsViewController: SettingsPaneController {
    private var buttons: [AppSettings.Appearance: NSButton] = [:]

    override func buildForm(_ form: SettingsForm) {
        for (index, appearance) in AppSettings.Appearance.allCases.enumerated() {
            let button = NSButton(radioButtonWithTitle: Self.title(of: appearance), target: self, action: #selector(choose(_:)))
            button.state = appearance == AppSettings.appearance ? .on : .off
            buttons[appearance] = button
            form.addRow(index == 0 ? "Erscheinungsbild" : "", button)
        }
    }

    private static func title(of appearance: AppSettings.Appearance) -> String {
        switch appearance {
        case .system: "System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    @objc private func choose(_ sender: NSButton) {
        guard let appearance = buttons.first(where: { $0.value === sender })?.key else { return }
        AppSettings.appearance = appearance
    }
}
