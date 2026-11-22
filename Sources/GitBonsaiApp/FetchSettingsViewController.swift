import AppKit
import GitEngine

/// Fetch: whether the visible repository fetches on activation, and how often it fetches while it stays visible.
final class FetchSettingsViewController: SettingsPaneController {
    override func buildForm(_ form: SettingsForm) {
        let activation = NSButton(checkboxWithTitle: String(localized: "Fetch on activation", bundle: .module), target: self, action: #selector(toggleActivation(_:)))
        activation.state = AppSettings.fetchOnActivation ? .on : .off
        form.addRow("Automatic fetch", activation)
        let minutes = Int(AutoFetchPolicy.activationThreshold / 60)
        form.addCaption(SettingsForm.caption("When the app becomes active or a tab becomes visible and the last fetch was more than \(minutes) minutes ago."))

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for minutes in AutoFetchPolicy.intervalChoices {
            popup.addItem(withTitle: minutes == 0 ? String(localized: "Off", bundle: .module, comment: "Periodic fetch is off.") : String(localized: "Every \(minutes) minutes", bundle: .module))
            popup.lastItem?.tag = minutes
        }
        popup.selectItem(withTag: AppSettings.autoFetchMinutes)
        if popup.selectedItem == nil { popup.selectItem(withTag: 0) }
        popup.target = self
        popup.action = #selector(choose(_:))
        popup.widthAnchor.constraint(equalToConstant: Theme.Settings.popupWidth).isActive = true
        form.addRow("Periodically", popup)
        form.addCaption(SettingsForm.caption("Only the visible repository, while the app is active, with git fetch --all --prune. Half as often on battery, not at all in Low Power Mode."))
    }

    @objc private func toggleActivation(_ sender: NSButton) {
        AppSettings.fetchOnActivation = sender.state == .on
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        AppSettings.autoFetchMinutes = sender.selectedTag()
    }
}
