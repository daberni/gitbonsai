import AppKit

/// Fetch: how often every open repository fetches on its own.
final class FetchSettingsViewController: SettingsPaneController {
    override func buildForm(_ form: SettingsForm) {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for minutes in AppSettings.autoFetchChoices {
            popup.addItem(withTitle: minutes == 0 ? "Aus" : "Alle \(minutes) Minuten")
            popup.lastItem?.tag = minutes
        }
        popup.selectItem(withTag: AppSettings.autoFetchMinutes)
        if popup.selectedItem == nil { popup.selectItem(withTag: 0) }
        popup.target = self
        popup.action = #selector(choose(_:))
        popup.widthAnchor.constraint(equalToConstant: Theme.Settings.popupWidth).isActive = true
        form.addRow("Automatisch holen", popup)
        form.addCaption(SettingsForm.caption("Jedes offene Repository führt dann git fetch --all --prune aus, solange es geöffnet ist."))
    }

    @objc private func choose(_ sender: NSPopUpButton) {
        AppSettings.autoFetchMinutes = sender.selectedTag()
    }
}
