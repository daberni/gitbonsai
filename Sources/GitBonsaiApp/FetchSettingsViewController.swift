import AppKit
import GitEngine

/// Fetch: whether the visible repository fetches on activation, and how often it fetches while it stays visible.
final class FetchSettingsViewController: SettingsPaneController {
    override func buildForm(_ form: SettingsForm) {
        let activation = NSButton(checkboxWithTitle: "Beim Aktivieren fetchen", target: self, action: #selector(toggleActivation(_:)))
        activation.state = AppSettings.fetchOnActivation ? .on : .off
        form.addRow("Automatisch holen", activation)
        let minutes = Int(AutoFetchPolicy.activationThreshold / 60)
        form.addCaption(SettingsForm.caption("Wenn die App aktiv oder ein Tab sichtbar wird und der letzte Fetch länger als \(minutes) Minuten her ist."))

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for minutes in AutoFetchPolicy.intervalChoices {
            popup.addItem(withTitle: minutes == 0 ? "Aus" : "Alle \(minutes) Minuten")
            popup.lastItem?.tag = minutes
        }
        popup.selectItem(withTag: AppSettings.autoFetchMinutes)
        if popup.selectedItem == nil { popup.selectItem(withTag: 0) }
        popup.target = self
        popup.action = #selector(choose(_:))
        popup.widthAnchor.constraint(equalToConstant: Theme.Settings.popupWidth).isActive = true
        form.addRow("Regelmäßig", popup)
        form.addCaption(SettingsForm.caption("Nur das sichtbare Repository, solange die App aktiv ist, mit git fetch --all --prune. Im Akkubetrieb doppelt so selten, im Stromsparmodus gar nicht."))
    }

    @objc private func toggleActivation(_ sender: NSButton) {
        AppSettings.fetchOnActivation = sender.state == .on
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        AppSettings.autoFetchMinutes = sender.selectedTag()
    }
}
